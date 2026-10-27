# frozen_string_literal: true

require "net/http"
require "yaml"

module Timekeeping
  # The invoice reservation adapter while the Timekeeping service owns the
  # entries (contracts/timekeeping/reservations.yml). It answers prepare,
  # commit, abort, mark_billed and admit with an Invoices::ReservationOutcome,
  # converting every HTTP answer itself, so callers never see a Net:: or JSON
  # error and never read an outcome from a bare 200.
  #
  # Each call carries a credential the minter makes for the request's own
  # company and the one operation of the route, never a user token. The path
  # and every body field come from the request, which delivery rebuilds from
  # the stored intent, so a replayed prepare is identical to the original.
  #
  # Commit and abort answer only counts, and the contract's first_terminal_wins
  # rule answers zero counts to an operation that is already finished. So a
  # non-zero count, which only the call that finished the operation can give,
  # settles the state; otherwise the identical prepare is replayed, and the
  # terminal_prepare rule makes it report the stored state.
  class ReservationClient
    # Raised by the transport for a failed exchange. Its message carries only
    # the method and the exception class, never the credential or the answer.
    class TransportError < StandardError; end

    # Sends one JSON request to TIMEKEEPING_BASE_URL. Every Net:: failure,
    # and an answer that is not JSON, raises TransportError.
    class NetHttpTransport
      Response = Data.define(:status, :body)

      def initialize(base_url: ENV[EntryApiClient::BASE_URL_ENV])
        @base_url = base_url.to_s
      end

      def call(method, path, headers: {}, body: nil)
        raise TransportError, "#{EntryApiClient::BASE_URL_ENV} is not set" if @base_url.blank?

        request = Net::HTTPGenericRequest.new(method.to_s.upcase, true, true, URI.join(@base_url, path))
        headers.each { |name, value| request[name] = value }
        request.body = JSON.generate(body) unless body.nil?
        response = send_request(request)
        Response.new(status: response.code.to_i, body: response.body.to_s.empty? ? nil : JSON.parse(response.body))
      rescue SystemCallError, IOError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError, Net::ProtocolError,
             JSON::ParserError => error
        raise TransportError, "Timekeeping #{method} failed: #{error.class}"
      end

      private

        def send_request(request)
          uri = request.uri
          Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                              open_timeout: EntryApiClient::TIMEOUT_SECONDS,
                                              read_timeout: EntryApiClient::TIMEOUT_SECONDS) do |connection|
            connection.request(request)
          end
        end
    end

    CONTRACT = YAML.safe_load_file(Rails.root.join("contracts/timekeeping/reservations.yml")).freeze
    ROUTES = CONTRACT.fetch("routes")
    OPERATION_STATES = CONTRACT.fetch("operation_states").freeze
    TERMINAL_STATES = (OPERATION_STATES - ["prepared"]).freeze
    CONFLICT_REASON = CONTRACT.dig("errors", "conflict", "reason")
    # The 409 reasons the contract asks the caller to retry.
    RETRYABLE_REASONS = [
      CONTRACT.dig("errors", "unresolved_operation", "reason"),
      CONTRACT.dig("errors", "stale_generation", "body", "reason")
    ].freeze

    ROUTE_OPERATIONS = {
      "prepare" => ServiceToken::RESERVATIONS_PREPARE,
      "commit" => ServiceToken::RESERVATIONS_COMMIT,
      "abort" => ServiceToken::RESERVATIONS_ABORT,
      "mark_billed" => ServiceToken::INVOICES_MARK_BILLED
    }.freeze

    # What a 200 body must hold for each route to count as answered.
    ANSWERED = {
      "prepare" => ->(body) { OPERATION_STATES.include?(body["state"]) },
      "commit" => ->(body) { body["reserved"].is_a?(Integer) && body["released"].is_a?(Integer) },
      "abort" => ->(body) { body["dropped"].is_a?(Integer) },
      "mark_billed" => ->(body) { body["billed"].is_a?(Integer) }
    }.freeze

    CONFLICT_STATUS = 409
    # Why an abort stays retryable when Timekeeping refuses its prepare
    # replay: no operation is stored, so nothing can be made terminal yet.
    REFUSED_REPLAY_REASON = "abort_replay_refused"
    # Why billing is refused when the entries Timekeeping would bill are not
    # the entries on the invoice's lines.
    BILLING_MISMATCH_REASON = "billing_entries_mismatch"

    # Builds the client production uses: Net::HTTP to TIMEKEEPING_BASE_URL
    # and a fresh ServiceToken per call.
    def self.build
      new(
        http: NetHttpTransport.new,
        credential: ->(company_id:, operation:) { ServiceToken.mint(company_id:, operations: [operation]) }
      )
    end

    # http: answers call(method, path, headers:, body:) with an object that
    # has status and a parsed body. credential: answers
    # call(company_id:, operation:) with a bearer credential.
    def initialize(http:, credential:)
      @http = http
      @credential = credential
    end

    # Refuses locally an entry another kept invoice claims, before anything
    # is sent, then asks Timekeeping to prepare.
    def prepare(request)
      conflicts = Invoices::LocalClaimCheck.call(request)
      return outcome("refused", conflicts:) if conflicts.any?

      remote_prepare(request)
    end

    # A sent invoice's added lines reserve nothing, and the contract has no
    # admit route, so admission is the local claim check alone.
    def admit(request)
      conflicts = Invoices::LocalClaimCheck.call(request)
      return outcome("refused", conflicts:) if conflicts.any?

      outcome("prepared", counts: { entries: request.entries.size })
    end

    def commit(request)
      answer = exchange("commit", request)
      return answer if answer.is_a?(Invoices::ReservationOutcome)

      counts = { reserved: answer["reserved"], released: answer["released"] }
      return outcome("committed", counts:) if counts.values.any?(&:positive?)

      stored_state(request)
    end

    # Replays the identical prepare first, so a prepare whose answer was lost
    # is stored and then made terminal, and a late copy of it cannot reserve.
    # A replay that stores no operation (refused or retryable) leaves nothing
    # terminal yet, so the abort stays retryable.
    def abort(request)
      replay = remote_prepare(request)
      return replay if TERMINAL_STATES.include?(replay.state)
      return outcome("retryable", reason: REFUSED_REPLAY_REASON) if replay.state == "refused"
      return replay unless replay.state == "prepared"

      answer = exchange("abort", request)
      return answer if answer.is_a?(Invoices::ReservationOutcome)
      return outcome("aborted", counts: { dropped: answer["dropped"] }) if answer["dropped"].positive?

      stored_state(request)
    end

    # The mark_billed route carries no entry list: Timekeeping bills the
    # reservations it holds as committed for the invoice, which are the
    # entries of the invoice's holding. Billing is refused when those differ
    # from the entries on the invoice's lines (a sent invoice that kept a
    # removed line's entry, or gained a line that reserved nothing), because
    # Timekeeping would then bill the wrong entries. An invoice with no
    # holding has no settled reservation set the monolith knows of, so what
    # Timekeeping would bill is unknown: every line entry is refused, and only
    # an invoice with no line entries bills with no holding.
    def mark_billed(request)
      held_ids = InvoiceEntryHolding.find_by(company_id: request.company_id, invoice_id: request.invoice_id)&.entry_ids || []
      mismatched_ids = (held_ids | request.entries) - (held_ids & request.entries)
      if mismatched_ids.any?
        return outcome("refused", conflicts: mismatched_ids.sort.map { |entry_id| { entry_id:, reason: BILLING_MISMATCH_REASON } })
      end

      answer = exchange("mark_billed", request)
      return answer if answer.is_a?(Invoices::ReservationOutcome)

      outcome("committed", counts: { billed: answer["billed"] })
    end

    private

      attr_reader :http, :credential

      def remote_prepare(request)
        answer = exchange("prepare", request)
        return answer if answer.is_a?(Invoices::ReservationOutcome)

        outcome(answer["state"])
      end

      # The operation's state as the replayed prepare reports it; anything
      # but a terminal state means the state is not settled yet.
      def stored_state(request)
        replay = remote_prepare(request)
        return replay if TERMINAL_STATES.include?(replay.state) || replay.state == "retryable"

        outcome("retryable", reason: "state_unsettled")
      end

      # Returns the 200 body when it holds what the route answers, or the
      # outcome every other answer maps to.
      def exchange(route, request)
        response = http.call(ROUTES.fetch(route).fetch("method"), path(route, request),
                             headers: headers(route, request), body: body(route, request))
        status = response.status.to_i
        answer = response.body
        return failure(status, answer) unless status == 200
        return outcome("retryable", reason: "malformed_answer") unless answer.is_a?(Hash) && ANSWERED.fetch(route).call(answer)

        answer
      rescue TransportError
        outcome("retryable", reason: "transport_error")
      rescue UserToken::Error
        outcome("retryable", reason: "credential_unavailable")
      end

      def failure(status, answer)
        reason = answer["reason"] if answer.is_a?(Hash)
        return conflict(answer) if status == CONFLICT_STATUS && reason == CONFLICT_REASON
        return outcome("retryable", reason:) if status == CONFLICT_STATUS && RETRYABLE_REASONS.include?(reason)
        return outcome("retryable", reason: "unavailable") if status >= 500

        outcome("retryable", reason: "unexpected_status_#{status}")
      end

      # The conflict reasons are kept exactly as sent, so the caller maps
      # them to its own messages.
      def conflict(answer)
        conflicts = Array(answer["conflicts"]).map do |item|
          { entry_id: item.fetch("entry_id"), reason: item.fetch("reason") }
        end
        outcome("refused", conflicts:)
      rescue KeyError, TypeError, NoMethodError
        outcome("retryable", reason: "malformed_answer")
      end

      def path(route, request)
        ROUTES.fetch(route).fetch("path")
          .gsub("{company_id}", Integer(request.company_id).to_s)
          .gsub("{invoice_id}", Integer(request.invoice_id).to_s)
      end

      def headers(route, request)
        token = credential.call(company_id: request.company_id, operation: ROUTE_OPERATIONS.fetch(route))
        { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
      end

      def body(route, request)
        ROUTES.fetch(route).fetch("request_fields").index_with { |field| request.public_send(field) }
      end

      def outcome(state, conflicts: [], counts: {}, reason: nil)
        Invoices::ReservationOutcome.new(state:, conflicts:, counts:, reason:)
      end
  end
end
