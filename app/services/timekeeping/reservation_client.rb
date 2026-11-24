# frozen_string_literal: true

module Timekeeping
  # The reservation adapter for entries the Timekeeping service owns
  # (contracts/timekeeping/reservations.yml). It takes an
  # Invoices::ReservationRequest and returns an Invoices::ReservationOutcome,
  # as every adapter does.
  #
  # Each call carries a Timekeeping::ServiceToken minted for the request's
  # company and the one operation of its route, never the shared
  # TIMEKEEPING_SERVICE_TOKEN, and no token is kept between calls. The path
  # company and every body field come only from the request, so a request is
  # never sent under another company or generation than the one it stores.
  #
  # The service's commit and abort answers carry no state, so both learn it by
  # replaying the identical prepare: the contract's terminal_prepare rule makes
  # a replay of a committed or aborted operation return that state and change
  # nothing.
  class ReservationClient
    CONTRACT = YAML.safe_load_file(Rails.root.join("contracts/timekeeping/reservations.yml"))
    ROUTES = CONTRACT.fetch("routes")
    ERRORS = CONTRACT.fetch("errors")
    OPERATION_STATES = CONTRACT.fetch("operation_states").freeze
    CONFLICT_REASONS = CONTRACT.fetch("conflict_reasons").freeze
    CONFLICT_STATUS = ERRORS.dig("conflict", "status")
    CONFLICT_REASON = ERRORS.dig("conflict", "reason").freeze
    # The fields of each item in prepare's "entries" answer: the entry id,
    # then the company the service holds it under.
    ENTRY_ID_FIELD, ENTRY_COMPANY_FIELD = ROUTES.dig("prepare", "response_entry_fields").map(&:freeze)
    # The conflict reason for an entry the service does not hold under the
    # request's company (the contract's company_mismatch rule).
    NOT_FOUND_REASON = CONFLICT_REASONS.find { |reason| reason == "not_found" } ||
                       raise(KeyError, "contracts/timekeeping/reservations.yml names no not_found conflict reason")

    COMMITTED = "committed"
    REFUSED = "refused"
    RETRYABLE = "retryable"

    OPERATIONS = {
      "prepare" => ServiceToken::RESERVATIONS_PREPARE,
      "commit" => ServiceToken::RESERVATIONS_COMMIT,
      "abort" => ServiceToken::RESERVATIONS_ABORT,
      "mark_billed" => ServiceToken::INVOICES_MARK_BILLED
    }.freeze

    # A new token on every call. A key that cannot be loaded becomes a
    # transport error, so the call answers retryable and nothing is sent.
    SERVICE_CREDENTIAL = lambda do |company_id:, operation:|
      ServiceToken.mint(company_id:, operations: [operation])
    rescue UserToken::MissingKeyError => error
      raise ReservationHttp::Error, "Timekeeping service token unavailable: #{error.class}"
    end

    # One row of the answer table: the status it answers, a check on the
    # parsed body, and the outcome fields it builds from that body.
    Row = Data.define(:status, :matches, :outcome)

    # The 409 answers the service names as safe to retry.
    RETRYABLE_ROWS = %w[unresolved_operation stale_generation].map do |name|
      error = ERRORS.fetch(name)
      reason = (error["reason"] || error.dig("body", "reason")).freeze
      Row.new(status: error.fetch("status"), matches: ->(body) { body["reason"] == reason },
              outcome: ->(_body) { { state: RETRYABLE, reason: } })
    end.freeze

    # A 409 conflict that names its conflicting entries.
    CONFLICT_ROW = Row.new(status: CONFLICT_STATUS,
                           matches: ->(body) { body["reason"] == CONFLICT_REASON && conflicts_in(body).any? },
                           outcome: ->(body) { { state: REFUSED, conflicts: conflicts_in(body) } })

    # How each kind of answer maps to an outcome. The first matching row wins;
    # an answer no row matches, including a body that is not a JSON object or
    # a request that never got an answer, is retryable. So nothing outside
    # this table is a success. A prepare 200 must list its entries in the
    # contract's shape, because the company of each one is checked against
    # the request; an answer that carries no companies cannot pass that check.
    ANSWER_TABLE = {
      prepare: [
        Row.new(status: 200,
                matches: ->(body) { OPERATION_STATES.include?(body["state"]) && !entries_in(body).nil? },
                outcome: ->(body) { { state: body["state"], entries: entries_in(body) } }),
        CONFLICT_ROW,
        *RETRYABLE_ROWS
      ],
      mark_billed: [
        Row.new(status: 200, matches: ->(body) { body["billed"].is_a?(Integer) },
                outcome: ->(body) { { state: COMMITTED, counts: { billed: body["billed"] } } }),
        CONFLICT_ROW,
        *RETRYABLE_ROWS
      ],
      # A commit or abort request that was not accepted.
      unacknowledged: RETRYABLE_ROWS
    }.freeze

    # The conflicts of a 409 conflict answer, or none when any item lacks an
    # integer entry_id or a reason the contract names. The reason is kept as
    # the service wrote it, because the refusal message shown to the user is
    # chosen from it.
    def self.conflicts_in(body)
      items = body["conflicts"]
      well_formed = items.is_a?(Array) && items.all? do |item|
        item.is_a?(Hash) && item["entry_id"].is_a?(Integer) && CONFLICT_REASONS.include?(item["reason"])
      end
      return [] unless well_formed

      items.map { |item| { entry_id: item["entry_id"], reason: item["reason"] } }
    end

    # The entries of a prepare 200, or nil when the list is missing or any
    # item lacks an integer entry id. A company may be null: the check in
    # `prepare` then refuses that entry as not found, as the monolith's own
    # check refuses an entry with no company.
    def self.entries_in(body)
      items = body["entries"]
      well_formed = items.is_a?(Array) && items.all? do |item|
        item.is_a?(Hash) && item[ENTRY_ID_FIELD].is_a?(Integer) &&
          (item[ENTRY_COMPANY_FIELD].nil? || item[ENTRY_COMPANY_FIELD].is_a?(Integer))
      end
      return nil unless well_formed

      items.map { |item| { entry_id: item[ENTRY_ID_FIELD], company_id: item[ENTRY_COMPANY_FIELD] } }
    end

    # The not_found conflicts for a prepare answer: every requested entry the
    # answer does not list under the request's company, then every listed
    # entry the request did not name. Empty when the answer confirms exactly
    # the requested entries.
    def self.company_mismatches(request, entries)
      confirmed = entries.filter_map { |entry| entry[:entry_id] if entry[:company_id] == request.company_id }
      unconfirmed = request.entries - confirmed
      unrequested = entries.pluck(:entry_id) - request.entries
      (unconfirmed + unrequested).uniq.map { |entry_id| { entry_id:, reason: NOT_FOUND_REASON } }
    end

    # http: answers call(method, path, headers:, body:) with an object that
    # has status and a string-keyed parsed body (Timekeeping::ReservationHttp
    # in production). credential: answers call(company_id:, operation:) with
    # the bearer token for one request.
    def initialize(http:, credential: SERVICE_CREDENTIAL)
      @http = http
      @credential = credential
    end

    # Prepares, then checks the company of every entry in the answer (rule L8
    # of docs/architecture/timekeeping-soa.md section 6.3): a 200 that does
    # not list exactly the requested entries, each under the request's
    # company, is refused with a not_found conflict for each entry it gets
    # wrong, so the save rolls back and its abort drops what the service held.
    def prepare(request)
      outcome = prepare_answer(request)
      return outcome unless OPERATION_STATES.include?(outcome.state)

      mismatches = self.class.company_mismatches(request, outcome.entries)
      return outcome if mismatches.empty?

      Invoices::ReservationOutcome.new(state: REFUSED, conflicts: mismatches, counts: {})
    end

    # Posts commit, then replays prepare and answers the state it reports. A
    # commit that is not accepted ends here: a replay of an operation the
    # service never stored would store a new prepared one.
    def commit(request)
      answer = send_route("commit", request)
      return outcome_for(:unacknowledged, answer) unless accepted?(answer)

      replayed_state(request)
    end

    # Replays prepare, posts abort and replays prepare again. A replay refused
    # by a conflict stored nothing, so a delayed copy of the original prepare
    # could still reserve later; the abort stays retryable until it makes the
    # operation terminal. The replays skip the company check: an operation
    # that failed it must still be aborted, or it would stay retryable for ever.
    def abort(request)
      first_replay = prepare_answer(request)
      answer = send_route("abort", request)
      final_replay = prepare_answer(request)
      return retryable(CONFLICT_REASON) if [first_replay, final_replay].any? { |replay| replay.state == REFUSED }
      return outcome_for(:unacknowledged, answer) unless accepted?(answer)

      final_replay
    end

    def mark_billed(request)
      outcome_for(:mark_billed, send_route("mark_billed", request))
    end

    # The contract has no admit route. A live sent invoice changes no
    # reservations, so the local claim check, which writes nothing, answers.
    def admit(request)
      Invoices::LegacyReservations.new.admit(request)
    end

    private

      # The prepare answer as the service gave it, without the company check.
      def prepare_answer(request)
        outcome_for(:prepare, send_route("prepare", request))
      end

      # Returns the answer, or nil when the request could not be sent or
      # answered.
      def send_route(name, request)
        route = ROUTES.fetch(name)
        token = @credential.call(company_id: request.company_id, operation: OPERATIONS.fetch(name))
        @http.call(route.fetch("method"), path_for(route, request),
                   headers: { "Authorization" => "Bearer #{token}" },
                   body: body_for(route, request))
      rescue ReservationHttp::Error
        nil
      end

      # The contract path with each {name} formatted from the request as an
      # integer, so no value can change the route.
      def path_for(route, request)
        format(route.fetch("path").gsub(/\{(\w+)\}/, '%<\1>d'),
               company_id: request.company_id, invoice_id: request.invoice_id)
      end

      # Built only from the request's stored fields, in the contract's field
      # order, so a replay or a retry from another client instance is the same
      # body the service stored. The request already holds its entries in
      # canonical order.
      def body_for(route, request)
        route.fetch("request_fields").index_with { |field| request.public_send(field) }
      end

      def accepted?(answer)
        !answer.nil? && (200..299).cover?(answer.status)
      end

      def replayed_state(request)
        replay = prepare_answer(request)
        replay.state == REFUSED ? retryable(CONFLICT_REASON) : replay
      end

      def outcome_for(kind, answer)
        body = answer&.body
        row = body.is_a?(Hash) && ANSWER_TABLE.fetch(kind).find do |candidate|
          candidate.status == answer.status && candidate.matches.call(body)
        end
        fields = row ? row.outcome.call(body) : { state: RETRYABLE }
        Invoices::ReservationOutcome.new(**{ conflicts: [], counts: {} }.merge(fields))
      end

      def retryable(reason)
        Invoices::ReservationOutcome.new(state: RETRYABLE, conflicts: [], counts: {}, reason:)
      end
  end
end
