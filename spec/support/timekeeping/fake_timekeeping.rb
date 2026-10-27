# frozen_string_literal: true

require "securerandom"

require_relative "client"
require_relative "contract"
require_relative "idempotency_receipts"
require_relative "reservation_rules"
# Required by path because the relay gem loads this fake under its own bundle,
# which does not include timekeeping_rules.
require_relative "../../../gems/timekeeping_rules/lib/timekeeping_rules"

module TimekeepingContract
  # An in-memory Timekeeping that answers the entry API and the reservation
  # operations of contracts/timekeeping/, and writes one entry snapshot to its
  # outbox for every change to an entry. Later lanes build against it.
  #
  # Every rule the contract examples check is a named policy passed in at
  # construction, so spec/contracts/timekeeping/mutation_spec.rb can break one
  # rule at a time and show the examples catch it. All state is per instance.
  #
  # Built with token_public_key:, the fake runs in token mode: it accepts only
  # Timekeeping::UserToken JWTs the monolith signed, takes the acting user,
  # company and roles from their verified claims, and applies the shared entry
  # change rules, so specs drive it with the monolith's own ids and real
  # tokens instead of stubbing the token check. On reservation routes it also
  # accepts Timekeeping::ServiceToken JWTs, checked as the real service checks
  # them. Without it, the fake accepts
  # the opaque tokens issue_token hands out, as the contract examples use.
  class FakeTimekeeping
    INITIAL_GENERATION = 1
    FIRST_ID = 1000
    CLOCK_START = Time.utc(2026, 1, 1)

    # The reservation wire carries no invoice status, so the fake, like the
    # real provider, applies the desired set it is sent. Keeping a non-draft
    # invoice's entries is the job of the boundary that builds that set.
    WIRE_INVOICE_STATUS = TimekeepingRules::ReservationDecision::DRAFT_STATUS

    # Who the body's user_id names, in order: the first row that holds decides.
    TARGET_USER_TABLE = [
      [->(request) { request[:requested_id].nil? || request[:requested_id] == request[:acting]["id"] }, :acting],
      [->(request) { !request[:privileged] }, :forbidden],
      [->(request) { request[:requested]&.fetch("company_id") != request[:acting]["company_id"] }, :not_found],
      [->(_request) { true }, :requested]
    ].freeze

    # Whether the agent and user an entry holds after a write may be
    # committed, in order: no agent, or an agent of the entry's company whose
    # user is the entry's user. Every other agent answers as a missing id.
    AGENT_OWNER_TABLE = [
      [->(pair) { pair[:agent_id].nil? }, :ok],
      [->(pair) { pair[:agent]&.fetch("company_id") != pair[:company_id] }, :not_found],
      [->(pair) { pair[:agent].fetch("user_id") != pair[:user_id] }, :not_found],
      [->(_pair) { true }, :ok]
    ].map(&:freeze).freeze

    # Whether a credential may call a reservation route, in order.
    SERVICE_ACCESS_TABLE = [
      [->(access) { access[:kind].nil? }, :unauthorized],
      [->(access) { access[:kind] == :user }, :forbidden],
      [->(access) { !access[:service].fetch("operations").include?(access[:operation]) }, :forbidden],
      [->(access) { access[:service].fetch("company_id") != access[:company_id] }, :not_found],
      [->(_access) { true }, :ok]
    ].freeze

    # The operation each reservation route runs, as a signed service token's
    # operations claim spells it. A copy of
    # timekeeping/app/services/timekeeping/reservation_access.rb
    # ROUTE_OPERATIONS, which the monolith cannot load.
    SERVICE_ROUTE_OPERATIONS = {
      "prepare" => "reservations.prepare",
      "commit" => "reservations.commit",
      "abort" => "reservations.abort",
      "mark_billed" => "invoices.mark_billed",
      "detach_entries" => "agents.detach_entries"
    }.freeze

    def self.first_match(table, facts)
      table.find { |condition, _result| condition.call(facts) }.last
    end

    POLICIES = {
      generation_current: ->(sent:, current:) { sent == current },
      entry_visible: ->(entry:, company_id:) { !entry.nil? && entry["discarded_at"].nil? && entry["company_id"] == company_id },
      locked: ->(reserved:, was_locked:) { reserved },
      duration: ->(stored) { stored },
      target_user: ->(**request) { first_match(TARGET_USER_TABLE, request) },
      agent_owner: ->(**pair) { first_match(AGENT_OWNER_TABLE, pair) },
      service_access: ->(**access) { first_match(SERVICE_ACCESS_TABLE, access) },
      operation_key: ->(company_id:, actor:, operation_id:) { [company_id, actor, operation_id] },
      # Which entries a refused prepare still reserves or releases: none.
      refused_prepare: ->(free_entry_ids:, conflicting_entry_ids:) { { reserve: [], release: [] } },
      # Whether a reservation route refused for its credential still runs its
      # command before answering the refusal: never.
      refused_command_writes: ->(route:) { false },
      # Whether an accepted mark_billed or detach_entries stores the changes
      # it counts: always.
      service_command_writes: ->(route:) { true },
      replay_terminal_prepare: true,
      # The section 7.2 prepare decision table the fake answers from.
      prepare_table: ReservationRules::PREPARE_TABLE,
      snapshot_entry: ->(entry, credentials:) { entry },
      # Whether an entry write carries a credential Timekeeping holds anywhere
      # in its body. Such a write is refused, so the snapshot it would publish
      # can never carry the credential.
      credential_in_body: lambda do |body:, credentials:|
        serialized = JSON.generate(body)
        credentials.any? { |credential| serialized.include?(credential) }
      end,
      receipt_key: IdempotencyReceipts::SCOPED_RECEIPT_KEY,
      reject_reused_key: true
    }.freeze

    ENTRY_WRITE_ROUTES = %w[create update destroy bulk_move bulk_delete].freeze

    attr_reader :generation, :outbox, :requests

    def initialize(policies: POLICIES, token_public_key: nil)
      @policies = POLICIES.merge(policies)
      @token_public_key = token_public_key
      @entry_contract = TimekeepingContract.load(:entry_api)
      @reservation_contract = TimekeepingContract.load(:reservations)
      @idempotency_contract = TimekeepingContract.load(:idempotency)
      @snapshot_contract = TimekeepingContract.load(:entry_snapshots)
      @entry_router = Router.new(@entry_contract.fetch("routes"))
      @reservation_router = Router.new(@reservation_contract.fetch("routes"))
      @receipts = IdempotencyReceipts.new(receipt_key: @policies[:receipt_key], reject_reused_key: @policies[:reject_reused_key])
      @generation = INITIAL_GENERATION
      @next_id = FIRST_ID
      @ticks = 0
      @users = {}
      @tokens = {}
      @services = {}
      @projects = {}
      @agents = {}
      @entries = {}
      @reservations = []
      @operations = {}
      @outbox = []
      @companies = {}
      @requests = []
    end

    def call(method, path, headers: {}, body: nil)
      headers = headers.to_h
      body = Wire.copy(body) || {}
      @requests += [{ method: method.to_s.upcase, path:, headers: Wire.copy(headers), body: Wire.copy(body) }]
      if (match = @entry_router.match(method, path))
        entry_request(*match, headers, body)
      elsif (match = @reservation_router.match(method, path))
        reservation_request(*match, headers, body)
      else
        Wire.error(@entry_contract, "not_found")
      end
    end

    # Setup used by FakeArrange. Real providers seed through their own stores.

    def add_company
      next_id
    end

    def add_user(company_id:, role:)
      next_id.tap { |id| @users[id] = { "id" => id, "company_id" => company_id, "role" => role } }
    end

    def issue_token(user_id)
      "test-user-token-#{SecureRandom.hex(8)}".tap { |token| @tokens[token] = user_id }
    end

    def add_service(company_id:, name:, operations:)
      "test-service-identity-#{SecureRandom.hex(8)}".tap do |credential|
        @services[credential] = { "company_id" => company_id, "name" => name, "operations" => operations }
      end
    end

    def service(credential)
      @services[credential]
    end

    def user_token?(credential)
      @tokens.key?(credential)
    end

    def add_project(company_id:)
      next_id.tap { |id| @projects[id] = company_id }
    end

    # Token-mode setup: records under the monolith's own ids, which the tokens
    # it signs and the bodies it forwards name. edit_days is the company's
    # timesheet edit window, which the change rules read.

    def register_company(id:, edit_days:)
      @companies[id] = { "edit_days" => edit_days }
    end

    def register_user(id:, company_id:, role:)
      @users[id] = { "id" => id, "company_id" => company_id, "role" => role }
    end

    def register_project(id:, company_id:)
      @projects[id] = company_id
    end

    def register_agent(id:, company_id:, user_id:)
      @agents[id] = { "company_id" => company_id, "user_id" => user_id }
    end

    def add_agent(company_id:, user_id:)
      next_id.tap { |id| @agents[id] = { "company_id" => company_id, "user_id" => user_id } }
    end

    def add_entry(company_id:, user_id:, project_id:, **attributes)
      fields = { "work_date" => "2026-03-02", "duration" => 60.0 }
        .merge(Wire.copy(attributes), "project_id" => project_id, "user_id" => user_id)
      write_entry(new_entry(company_id, fields))
    end

    def add_reservation(entry_id:, invoice_id:, state:, disposition:)
      company_id = @entries.fetch(entry_id).fetch("company_id")
      @reservations += [{ company_id:, entry_id:, invoice_id:, state:, disposition:, operation_key: "arranged-#{next_id}" }]
      refresh_locked([entry_id])
    end

    def generation=(generation)
      @generation = Integer(generation)
    end

    def entry_locked?(entry_id)
      @entries.fetch(entry_id).fetch("locked")
    end

    def stored_entry(entry_id)
      Wire.copy(@entries.fetch(entry_id))
    end

    def reservations_for(entry_id)
      @reservations.filter_map do |reservation|
        { "invoice_id" => reservation[:invoice_id], "state" => reservation[:state] } if reservation[:entry_id] == entry_id
      end
    end

    def credentials
      @tokens.keys + @services.keys
    end

    private

      def next_id
        @next_id += 1
      end

      def now
        (CLOCK_START + (@ticks += 1)).iso8601
      end

      def integer(value)
        Integer(value, exception: false)
      end

      def respond(status, body)
        Response.new(status:, body: Wire.copy(body))
      end

      def generation_current?(sent)
        @policies[:generation_current].call(sent: integer(sent), current: @generation)
      end

      def visible_entry(id, company_id)
        entry = @entries[integer(id)]
        entry if @policies[:entry_visible].call(entry:, company_id:)
      end

      # Entry API

      def entry_request(route, params, headers, body)
        company_id = integer(params["company_id"])
        acting = acting_user(route, headers)
        return Wire.error(@entry_contract, "unauthorized") unless acting
        return Wire.error(@entry_contract, "not_found") unless acting.fetch("company_id") == company_id
        return entry_route(route, company_id, acting, params, headers, body) unless ENTRY_WRITE_ROUTES.include?(route)
        # The request's own bearer counts too: in token mode a signed token is
        # never stored in credentials, and the real service refuses it as well.
        held = (credentials + [Wire.bearer(headers)]).compact.reject(&:empty?).uniq
        return Wire.error(@entry_contract, "credential_in_body") if @policies[:credential_in_body].call(body:, credentials: held)
        return respond(400, "reason" => "bad_request") if malformed_duration?(body)

        # The generation is checked after the receipt, as Timekeeping::EntryWriter
        # does, so a retry of a committed write replays even after the
        # generation has moved.
        @receipts.answer(company_scope: company_id, actor: ["user", acting["id"]], operation: "#{route} #{params["entry_id"]}",
                         key: headers["Idempotency-Key"], body:) do
          next Wire.error(@entry_contract, "not_found") if replay_only?(route, headers)
          next Wire.error(@entry_contract, "stale_generation") unless generation_current?(headers["Ownership-Generation"])

          entry_route(route, company_id, acting, params, headers, body)
        end
      end

      # A replay-only DELETE is answered only from a stored receipt; with none
      # it is not_found and nothing is written (entry_api.yml headers).
      def replay_only?(route, headers)
        route == "destroy" && headers["Idempotency-Replay"] == "only"
      end

      # In token mode, which stands in for the real service, a duration must be
      # a JSON number, as Timekeeping::EntryCommand requires. Opaque-token mode
      # keeps the contract fake's looser input.
      def malformed_duration?(body)
        !@token_public_key.nil? && body.key?("duration") && !body["duration"].is_a?(Numeric)
      end

      # The acting user Hash for the request's bearer, or nil when it is not
      # accepted. In token mode a read token is refused on every write route,
      # as Timekeeping refuses it.
      def acting_user(route, headers)
        return @users[@tokens[Wire.bearer(headers)]] unless @token_public_key

        claims = Timekeeping::UserToken.verify(Wire.bearer(headers), public_key: @token_public_key)
        return nil if ENTRY_WRITE_ROUTES.include?(route) && claims.purpose != "write"

        { "id" => claims.user_id, "company_id" => claims.company_id, "role" => claims.role,
          "primary_role" => claims.primary_role }
      rescue Timekeeping::UserToken::InvalidTokenError
        nil
      end

      def entry_route(route, company_id, acting, params, headers, body)
        case route
        when "create" then create_entry(company_id, acting, body)
        when "update" then update_entry(company_id, acting, params, headers, body)
        when "destroy" then destroy_entry(company_id, acting, params, headers)
        when "show" then show_entry(company_id, params)
        when "index" then list_entries(company_id, params)
        when "bulk_move"
          bulk_change(company_id, acting, body, action: :move, result: "moved") { |entry| entry.merge("project_id" => body["project_id"]) }
        when "bulk_delete"
          bulk_change(company_id, acting, body, action: :delete, result: "deleted") { |entry| entry.merge("discarded_at" => now) }
        end
      end

      def create_entry(company_id, acting, body)
        user_id, failure = target_user(acting, body)
        return failure if failure
        return Wire.error(@entry_contract, "not_found") unless @projects[integer(body["project_id"])] == company_id

        fields = entry_fields(body).merge("user_id" => user_id)
        return Wire.error(@entry_contract, "not_found") unless agent_owned?(company_id, fields)

        review_status = TimekeepingRules::EntryRules.created_review_status(agent_id: fields["agent_id"])
        entry = write_entry(new_entry(company_id, fields).merge("review_status" => review_status))
        respond(201, present(entry))
      end

      def update_entry(company_id, acting, params, headers, body)
        entry = visible_entry(params["entry_id"], company_id)
        return Wire.error(@entry_contract, "not_found") unless entry

        return Wire.error(@entry_contract, "version_conflict") if stale_if_match?(headers, entry)

        refusal = change_refusal(company_id, acting, entry, action: :update, bill_status: body["bill_status"])
        return refusal if refusal

        changes = entry_fields(body)
        if body.key?("user_id")
          user_id, failure = target_user(acting, body)
          return failure if failure

          changes["user_id"] = user_id
        end
        if changes.key?("project_id") && @projects[integer(changes["project_id"])] != company_id
          return Wire.error(@entry_contract, "not_found")
        end

        committed = entry.merge(changes)
        return Wire.error(@entry_contract, "not_found") unless agent_owned?(company_id, committed)

        respond(200, present(write_entry(committed)))
      end

      # S7, checked on the agent and user the entry holds after the write, so
      # an update that changes only user_id under a stored agent is refused.
      def agent_owned?(company_id, fields)
        agent_id = fields["agent_id"]
        @policies[:agent_owner].call(agent_id:, agent: @agents[agent_id], user_id: fields["user_id"], company_id:) == :ok
      end

      def destroy_entry(company_id, acting, params, headers)
        entry = visible_entry(params["entry_id"], company_id)
        return Wire.error(@entry_contract, "not_found") unless entry
        return Wire.error(@entry_contract, "version_conflict") if stale_if_match?(headers, entry)

        refusal = change_refusal(company_id, acting, entry, action: :delete, bill_status: nil)
        return refusal if refusal

        respond(200, present(write_entry(entry.merge("discarded_at" => now))))
      end

      # A missing If-Match leaves the version unchecked, as Timekeeping does.
      def stale_if_match?(headers, entry)
        if_match = headers["If-Match"]
        !if_match.nil? && integer(if_match) != entry["version"]
      end

      # The shared entry change rules (A2 to A7) Timekeeping applies to a
      # user's update or delete, decided on the token's role and primary role.
      # Only token mode applies them: an opaque token carries no primary role.
      def change_refusal(company_id, acting, entry, action:, bill_status:)
        return nil unless @token_public_key

        decision = TimekeepingRules::EntryRules.change_decision(
          caller: TimekeepingRules::EntryRules::USER_DELEGATED, change: { action:, bill_status: },
          role: acting["role"], primary_role: acting["primary_role"], acting_user_id: acting["id"],
          entry: entry_rule_facts(entry),
          edit_days: @companies.fetch(company_id).fetch("edit_days"), today: Date.current
        )
        Wire.error(@entry_contract, decision.to_s) unless decision == :ok
      end

      def show_entry(company_id, params)
        entry = visible_entry(params["entry_id"], company_id)
        entry ? respond(200, present(entry)) : Wire.error(@entry_contract, "not_found")
      end

      def list_entries(company_id, params)
        filters = params.slice("user_id", "project_id").reject { |_field, value| value.to_s.empty? }
          .transform_values { |value| integer(value) }
        entries = @entries.values.select do |entry|
          @policies[:entry_visible].call(entry:, company_id:) &&
            filters.all? { |field, value| entry[field] == value } &&
            (params["from"].to_s.empty? || entry["work_date"] >= params["from"]) &&
            (params["to"].to_s.empty? || entry["work_date"] <= params["to"])
        end
        respond(200, "entries" => entries.map { |entry| present(entry) })
      end

      # Every visible entry is decided before any is written, as
      # Timekeeping::EntryWriter#bulk_change does, so a refused request writes
      # nothing. A skipped entry is reported as not_found, the contract having
      # no other result for it.
      def bulk_change(company_id, acting, body, action:, result:)
        if body.key?("project_id") && @projects[integer(body["project_id"])] != company_id
          return Wire.error(@entry_contract, "not_found")
        end

        entries = Array(body["entry_ids"]).filter_map { |entry_id| visible_entry(entry_id, company_id) }.uniq { |entry| entry["id"] }
        decision = bulk_rules_decision(company_id, acting, entries, action:)
        return Wire.error(@entry_contract, "forbidden") if decision == :forbidden

        applied = entries.select { |entry| decision.fetch(entry["id"]) == :apply }
        applied.each { |entry| write_entry(yield(entry)) }
        applied_ids = applied.pluck("id")
        results = Array(body["entry_ids"]).map do |entry_id|
          { "entry_id" => entry_id, "result" => applied_ids.include?(integer(entry_id)) ? result : "not_found" }
        end
        respond(200, "results" => results)
      end

      # The shared bulk rules (A9) Timekeeping applies, decided on the token's
      # role and primary role. Only token mode applies them, as change_refusal
      # does: an opaque token carries no primary role, so every visible entry
      # is applied.
      def bulk_rules_decision(company_id, acting, entries, action:)
        return entries.to_h { |entry| [entry["id"], :apply] } unless @token_public_key

        TimekeepingRules::EntryRules.bulk_decision(
          caller: TimekeepingRules::EntryRules::USER_DELEGATED, change: { action: },
          role: acting["role"], primary_role: acting["primary_role"], acting_user_id: acting["id"],
          entries: entries.map { |entry| entry_rule_facts(entry) },
          edit_days: @companies.fetch(company_id).fetch("edit_days"), today: Date.current
        )
      end

      # The entry facts the shared rules read, from a stored entry.
      def entry_rule_facts(entry)
        {
          id: entry["id"], user_id: entry["user_id"], bill_status: entry["bill_status"], locked: entry["locked"],
          work_date: entry["work_date"].nil? ? nil : Date.iso8601(entry["work_date"].to_s)
        }
      end

      # Returns [user id] or [nil, error response] for the body's user_id.
      def target_user(acting, body)
        requested_id = body["user_id"].nil? ? nil : integer(body["user_id"])
        decision = @policies[:target_user].call(
          acting:, requested_id:, requested: @users[requested_id],
          privileged: @entry_contract.fetch("privileged_roles").include?(acting["role"])
        )
        case decision
        when :acting then [acting["id"]]
        when :requested then [requested_id]
        else [nil, Wire.error(@entry_contract, decision.to_s)]
        end
      end

      def entry_fields(body)
        request = @entry_contract.fetch("request")
        body.slice(*(request.fetch("entry_required_fields") + request.fetch("entry_optional_fields") - ["user_id"]))
      end

      def new_entry(company_id, fields)
        time = now
        defaults = @snapshot_contract.fetch("entry_fields").index_with(nil).merge(
          "id" => next_id, "company_id" => company_id, "version" => 0, "note" => "", "bill_status" => "unbilled",
          "review_status" => "not_required", "locked" => false, "source" => "manual", "source_metadata" => {},
          "proof_metadata" => {}, "created_at" => time
        )
        defaults.merge(fields.slice(*defaults.keys))
      end

      # Stores a changed entry with a higher version and writes its snapshot to
      # the outbox, as Timekeeping does in the same transaction as the change.
      def write_entry(entry)
        stored = entry.merge("version" => entry["version"] + 1, "updated_at" => now)
        @entries[stored["id"]] = stored
        snapshot = @policies[:snapshot_entry].call(snapshot_fields(stored), credentials:)
        @outbox += [{ "generation" => @generation, "outbox_position" => @outbox.size + 1, "entry" => Wire.copy(snapshot) }]
        stored
      end

      def snapshot_fields(entry)
        entry.slice(*@snapshot_contract.fetch("entry_fields")).merge("duration" => @policies[:duration].call(entry["duration"]))
      end

      def present(entry)
        entry.slice(*@entry_contract.dig("response", "entry_fields"))
          .merge("duration" => @policies[:duration].call(entry["duration"]))
      end

      # Reservations and service commands

      def reservation_request(route, params, headers, body)
        company_id = integer(params["company_id"])
        actor, failure = authorize_service(Wire.bearer(headers), company_id, route)
        if failure
          run_reservation_route(route, company_id, actor, params, body) if @policies[:refused_command_writes].call(route:)
          return failure
        end
        return Wire.error(@reservation_contract, "stale_generation") unless generation_current?(body["generation"])

        run_reservation_route(route, company_id, actor, params, body)
      end

      def run_reservation_route(route, company_id, actor, params, body)
        case route
        when "prepare" then prepare(company_id, actor, body)
        when "commit", "abort" then finish(route, company_id, actor, body)
        when "mark_billed" then mark_billed(company_id, actor, params, body)
        when "detach_entries" then detach_entries(company_id, actor, params, body)
        end
      end

      # Returns [actor] or [nil, error response].
      def authorize_service(credential, company_id, route)
        service, operation = @services[credential] ? [@services[credential], route] : signed_service(credential, route)
        kind = (:service if service) || (:user if user_token?(credential))
        decision = @policies[:service_access].call(kind:, service:, company_id:, operation:)
        return [nil, Wire.error(@reservation_contract, decision.to_s)] unless decision == :ok

        [service ? ["service", service["name"]] : ["user", @tokens[credential]]]
      end

      # In token mode, a Timekeeping::ServiceToken the monolith signed, as the
      # service record and route operation SERVICE_ACCESS_TABLE reads, or
      # [nil, route] when the credential is not one. Only operations the
      # background allowlist also holds are granted, as
      # Timekeeping::ReservationAccess grants them, so a token naming any
      # other string, such as the bare route name, is refused.
      def signed_service(credential, route)
        return [nil, route] unless @token_public_key

        claims = Timekeeping::ServiceToken.verify(credential, public_key: @token_public_key)
        granted = claims.operations & TimekeepingRules::EntryRules::BACKGROUND_OPERATIONS
        [{ "company_id" => claims.company_id, "name" => claims.subject, "operations" => granted },
         SERVICE_ROUTE_OPERATIONS.fetch(route)]
      rescue Timekeeping::ServiceToken::InvalidTokenError
        [nil, route]
      end

      def operation(company_id, actor, operation_id)
        @operations[@policies[:operation_key].call(company_id:, actor:, operation_id:)]
      end

      def prepare(company_id, actor, body)
        existing = operation(company_id, actor, body["operation_id"])
        if existing
          return Wire.error(@idempotency_contract, "key_reused") unless existing[:request] == body
          return prepare_answer(existing) if existing[:state] == "prepared" || @policies[:replay_terminal_prepare]
        end

        unresolved = @operations.values.find do |other|
          other[:company_id] == company_id && other[:invoice_id] == body["invoice_id"] && other[:state] == "prepared"
        end
        if unresolved
          unresolved_error = @reservation_contract.dig("errors", "unresolved_operation")
          return respond(unresolved_error.fetch("status"), "reason" => unresolved_error.fetch("reason"),
                                                           "operation_id" => unresolved[:operation_id],
                                                           "retryable" => unresolved_error.fetch("retryable"))
        end

        entry_ids = Array(body["entries"]).map { |id| integer(id) }
        # Prepare answers from the swappable prepare_table policy, so the
        # mutation spec can break one row of it; commit's release still comes
        # from TimekeepingRules::ReservationDecision.
        outcomes = entry_ids.uniq.map { |entry_id| [entry_id, prepare_outcome(entry_id, company_id, body["invoice_id"])] }
        conflicts = outcomes.filter_map do |entry_id, outcome|
          { entry_id:, reason: outcome } if ReservationRules.refusal?(outcome)
        end
        free = outcomes.filter_map { |entry_id, outcome| entry_id if outcome == :add_provisional }
        operation_id = body["operation_id"]
        # Reservations carry the operation's full identity, so another actor's
        # operation with the same operation_id never commits or aborts them.
        operation_key = @policies[:operation_key].call(company_id:, actor:, operation_id:)

        unless conflicts.empty?
          refused = @policies[:refused_prepare].call(free_entry_ids: free, conflicting_entry_ids: conflicts.pluck(:entry_id))
          reserve_provisionally(refused[:reserve], company_id, body, operation_key)
          release(refused[:release])
          conflict_error = @reservation_contract.dig("errors", "conflict")
          return respond(conflict_error.fetch("status"),
                         "reason" => conflict_error.fetch("reason"),
                         "conflicts" => conflicts.map { |conflict| { "entry_id" => conflict[:entry_id], "reason" => conflict[:reason].to_s } })
        end

        reserve_provisionally(free, company_id, body, operation_key)
        stored = {
          key: operation_key, company_id:, operation_id:, invoice_id: body["invoice_id"], state: "prepared", request: body,
          desired_entry_ids: entry_ids, disposition: body["disposition"]
        }
        @operations[operation_key] = stored
        prepare_answer(stored)
      end

      def prepare_outcome(entry_id, company_id, invoice_id)
        current = @reservations.select { |reservation| reservation[:entry_id] == entry_id }
        facts = {
          in_company: !visible_entry(entry_id, company_id).nil?,
          committed: current.find { |reservation| reservation[:state] == "committed" },
          provisional: current.find { |reservation| reservation[:state] == "provisional" },
          invoice_id:
        }
        ReservationRules.prepare_outcome(facts, table: @policies[:prepare_table])
      end

      # Each entry's reservations in the form ReservationDecision reads, seen
      # from invoice_id.
      def decision_reservations(entry_ids, invoice_id)
        entry_ids.index_with do |entry_id|
          @reservations.filter_map do |reservation|
            next unless reservation[:entry_id] == entry_id

            { invoice: reservation[:invoice_id] == invoice_id ? :this : :other,
              state: reservation[:state], disposition: reservation[:disposition] }
          end
        end
      end

      def prepare_answer(operation)
        respond(200, "operation_id" => operation[:operation_id], "state" => operation[:state],
                     "entries" => operation[:desired_entry_ids].map { |id| { "entry_id" => id, "company_id" => operation[:company_id] } })
      end

      def reserve_provisionally(entry_ids, company_id, body, operation_key)
        @reservations += entry_ids.map do |entry_id|
          { company_id:, entry_id:, invoice_id: body["invoice_id"], state: "provisional", disposition: body["disposition"], operation_key: }
        end
        refresh_locked(entry_ids)
      end

      def release(entry_ids)
        @reservations = @reservations.reject { |reservation| entry_ids.include?(reservation[:entry_id]) }
        refresh_locked(entry_ids)
      end

      # Commit and abort act only on what prepare stored. After the first of
      # them, the operation is terminal and a later one changes nothing.
      def finish(route, company_id, actor, body)
        @receipts.answer(company_scope: company_id, actor:, operation: route, key: body["operation_id"], body:) do
          stored = operation(company_id, actor, body["operation_id"])
          next Wire.error(@reservation_contract, "not_found") unless stored && stored[:invoice_id] == body["invoice_id"]

          route == "commit" ? commit(stored) : abort_operation(stored)
        end
      end

      def commit(operation)
        return respond(200, "reserved" => 0, "released" => 0) unless operation[:state] == "prepared"

        mine = own_provisional(operation)
        reserved_ids = mine.pluck(:entry_id)
        held = @reservations.select do |reservation|
          reservation[:company_id] == operation[:company_id] && reservation[:invoice_id] == operation[:invoice_id] &&
            reservation[:state] == "committed"
        end
        released_ids = TimekeepingRules::ReservationDecision.call(
          current: decision_reservations(held.pluck(:entry_id).uniq, operation[:invoice_id]),
          desired: operation[:desired_entry_ids], disposition: operation[:disposition], invoice_status: WIRE_INVOICE_STATUS
        )[:release]

        @reservations = @reservations.reject do |reservation|
          (reservation[:state] == "committed" && reserved_ids.include?(reservation[:entry_id])) ||
            (held.include?(reservation) && released_ids.include?(reservation[:entry_id]))
        end
        @reservations = @reservations.map do |reservation|
          next reservation unless mine.include?(reservation) || held.include?(reservation)

          reservation.merge(state: "committed", disposition: operation[:disposition])
        end
        operation[:state] = "committed"
        refresh_locked(reserved_ids + released_ids)
        respond(200, "reserved" => reserved_ids.size, "released" => released_ids.size)
      end

      def abort_operation(operation)
        return respond(200, "dropped" => 0) unless operation[:state] == "prepared"

        mine = own_provisional(operation)
        @reservations -= mine
        operation[:state] = "aborted"
        refresh_locked(mine.pluck(:entry_id))
        respond(200, "dropped" => mine.size)
      end

      def own_provisional(operation)
        @reservations.select do |reservation|
          reservation[:operation_key] == operation[:key] && reservation[:state] == "provisional"
        end
      end

      def mark_billed(company_id, actor, params, body)
        invoice_id = integer(params["invoice_id"])
        @receipts.answer(company_scope: company_id, actor:, operation: "mark_billed #{invoice_id}", key: body["operation_id"],
                         body:) do
          held = @reservations.select do |reservation|
            reservation[:company_id] == company_id && reservation[:invoice_id] == invoice_id && reservation[:state] == "committed"
          end
          entries = held.filter_map { |reservation| visible_entry(reservation[:entry_id], company_id) }
            .reject { |entry| entry["bill_status"] == "billed" }
          if @policies[:service_command_writes].call(route: "mark_billed")
            entries.each { |entry| write_entry(entry.merge("bill_status" => "billed")) }
          end
          respond(200, "billed" => entries.size)
        end
      end

      def detach_entries(company_id, actor, params, body)
        agent_id = integer(params["agent_id"])
        @receipts.answer(company_scope: company_id, actor:, operation: "detach_entries #{agent_id}", key: body["operation_id"],
                         body:) do
          entries = @entries.values.select do |entry|
            entry["company_id"] == company_id && entry["agent_id"] == agent_id
          end
          if @policies[:service_command_writes].call(route: "detach_entries")
            entries.each { |entry| write_entry(entry.merge("agent_id" => nil)) }
            # The agent is being deleted, so a create that arrives after the
            # detach, such as one whose caller timed out, answers not_found
            # through the agent_owner rule, as Timekeeping refuses it.
            @agents.delete(agent_id) if @agents[agent_id]&.fetch("company_id") == company_id
          end
          respond(200, "detached" => entries.size)
        end
      end

      # locked mirrors whether the entry has any reservation; a change to it is
      # a change to the entry, so it raises the version and writes a snapshot.
      def refresh_locked(entry_ids)
        entry_ids.uniq.each do |entry_id|
          entry = @entries[entry_id]
          next unless entry

          reserved = @reservations.any? { |reservation| reservation[:entry_id] == entry_id }
          locked = @policies[:locked].call(reserved:, was_locked: entry["locked"])
          write_entry(entry.merge("locked" => locked)) unless locked == entry["locked"]
        end
      end
  end
end
