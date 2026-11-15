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

    # How each kind of answer maps to an outcome. The first matching row wins;
    # an answer no row matches, including a body that is not a JSON object or
    # a request that never got an answer, is retryable. So nothing outside
    # this table is a success.
    ANSWER_TABLE = {
      prepare: [
        Row.new(status: 200, matches: ->(body) { OPERATION_STATES.include?(body["state"]) },
                outcome: ->(body) { { state: body["state"] } }),
        Row.new(status: CONFLICT_STATUS,
                matches: ->(body) { body["reason"] == CONFLICT_REASON && conflicts_in(body).any? },
                outcome: ->(body) { { state: REFUSED, conflicts: conflicts_in(body) } }),
        *RETRYABLE_ROWS
      ],
      mark_billed: [
        Row.new(status: 200, matches: ->(body) { body["billed"].is_a?(Integer) },
                outcome: ->(body) { { state: COMMITTED, counts: { billed: body["billed"] } } }),
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

    # http: answers call(method, path, headers:, body:) with an object that
    # has status and a string-keyed parsed body (Timekeeping::ReservationHttp
    # in production). credential: answers call(company_id:, operation:) with
    # the bearer token for one request.
    def initialize(http:, credential: SERVICE_CREDENTIAL)
      @http = http
      @credential = credential
    end

    def prepare(request)
      outcome_for(:prepare, send_route("prepare", request))
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
    # operation terminal.
    def abort(request)
      first_replay = prepare(request)
      answer = send_route("abort", request)
      final_replay = prepare(request)
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
        replay = prepare(request)
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
