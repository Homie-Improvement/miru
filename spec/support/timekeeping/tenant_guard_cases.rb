# frozen_string_literal: true

# The declared cross-tenant cases of the Timekeeping tenant guard, one record
# per case, and a pure builder for the requests each case sends.
# TenantGuardSurfaces decides which cases are owed; this table is what the
# guard runs, and the meta spec checks the two against each other.
#
# A probe is the requester's own valid request with exactly one identifier
# swapped for the owner's. A replay sends the owner's recorded request with only
# the company and the credential replaced; it is used where the owner's key with
# an otherwise valid body would be a new, valid write, because another
# company's key never matches (idempotency.yml).
module TenantGuardCases
  # expected holds status and reason, plus results (bulk) or conflicts
  # (prepare) where the answer names the swapped entry. FOREIGN_ENTRY stands for
  # that entry until expected_answer resolves it against the owner's ids.
  Case = Data.define(:contract, :route, :mode, :covers, :credential, :first, :expected, :headers) do
    def initialize(covers:, expected:, headers:, **fields)
      super(
        covers: TenantGuardCases.frozen_copy(covers),
        expected: TenantGuardCases.frozen_copy(expected),
        headers: TenantGuardCases.frozen_copy(headers),
        **fields
      )
    end
  end

  FOREIGN_ENTRY = :foreign

  # Each contract's routes accept one kind of credential.
  CREDENTIALS = {
    entry_api: :user_token,
    reservations: :service_token,
    handoff: :service_token,
    entry_snapshots: :timekeeping_service,
    reference: :timekeeping_service
  }.freeze

  NOT_FOUND = { status: 404, reason: "not_found" }.freeze
  OK = { status: 200, reason: nil }.freeze
  BULK_ENTRY_NOT_FOUND = { status: 200, reason: nil, results: [{ entry_id: FOREIGN_ENTRY, result: "not_found" }] }.freeze
  PREPARE_ENTRY_CONFLICT = {
    status: 409, reason: "conflict", conflicts: [{ entry_id: FOREIGN_ENTRY, reason: "not_found" }]
  }.freeze
  STALE_GENERATION = { status: 409, reason: "stale_generation" }.freeze
  UNAUTHORIZED = { status: 401, reason: "unauthorized" }.freeze

  # entry_api rules.replay_only: these headers make a DELETE or bulk delete
  # answer only from a stored receipt, so a key probe can never discard an entry.
  REPLAY_ONLY_HEADERS = {
    "Idempotency-Replay" => "only", "If-Match" => "replay-only", "Ownership-Generation" => "replay-only"
  }.freeze

  # [contract, route, mode, covers, first, expected, headers]. Identifier
  # probes on update, destroy, bulk_move, bulk_delete, prepare, commit, abort,
  # mark_billed and detach_entries run the requester first: the owner's
  # positive control discards or changes its row, which would make the
  # requester miss for the wrong reason. Every other identifier case (replays,
  # reads and snapshot delivery) runs the owner first, so the owner's row or
  # receipt is shown to exist. No-identifier cases send only the requester's
  # request, so the requester runs first.
  ROWS = [
    [:entry_api, :create, :replay, %i[idempotency_key], :owner, NOT_FOUND, {}],
    [:entry_api, :update, :probe, %i[entry_id], :requester, NOT_FOUND, {}],
    [:entry_api, :update, :replay, %i[idempotency_key], :owner, NOT_FOUND, {}],
    [:entry_api, :destroy, :probe, %i[entry_id], :requester, NOT_FOUND, {}],
    [:entry_api, :destroy, :probe, %i[idempotency_key], :requester, NOT_FOUND, REPLAY_ONLY_HEADERS],
    [:entry_api, :show, :probe, %i[entry_id], :owner, NOT_FOUND, {}],
    [:entry_api, :index, :probe, %i[none], :requester, OK, {}],
    [:entry_api, :bulk_move, :probe, %i[entry_id], :requester, BULK_ENTRY_NOT_FOUND, {}],
    # B's body names B's project, which EntryWriter refuses before the bulk writer runs.
    [:entry_api, :bulk_move, :replay, %i[idempotency_key], :owner, NOT_FOUND, {}],
    [:entry_api, :bulk_delete, :probe, %i[entry_id], :requester, BULK_ENTRY_NOT_FOUND, {}],
    [:entry_api, :bulk_delete, :probe, %i[idempotency_key], :requester, NOT_FOUND, REPLAY_ONLY_HEADERS],
    [:reservations, :prepare, :probe, %i[invoice_id], :requester, NOT_FOUND, {}],
    [:reservations, :prepare, :probe, %i[entry_id], :requester, PREPARE_ENTRY_CONFLICT, {}],
    [:reservations, :prepare, :probe, %i[operation_id], :requester, NOT_FOUND, {}],
    [:reservations, :prepare, :replay, %i[idempotency_key], :owner, NOT_FOUND, {}],
    [:reservations, :commit, :probe, %i[invoice_id], :requester, NOT_FOUND, {}],
    # The body operation_id is the reservations key, so one swap covers both kinds.
    [:reservations, :commit, :probe, %i[operation_id idempotency_key], :requester, NOT_FOUND, {}],
    [:reservations, :abort, :probe, %i[invoice_id], :requester, NOT_FOUND, {}],
    [:reservations, :abort, :probe, %i[operation_id idempotency_key], :requester, NOT_FOUND, {}],
    [:reservations, :mark_billed, :probe, %i[invoice_id], :requester, NOT_FOUND, {}],
    [:reservations, :mark_billed, :probe, %i[operation_id], :requester, NOT_FOUND, {}],
    [:reservations, :mark_billed, :replay, %i[idempotency_key], :owner, NOT_FOUND, {}],
    [:reservations, :detach_entries, :probe, %i[operation_id], :requester, NOT_FOUND, {}],
    [:reservations, :detach_entries, :replay, %i[idempotency_key], :owner, NOT_FOUND, {}],
    [:entry_snapshots, :deliver, :probe, %i[entry_id], :owner, STALE_GENERATION, {}],
    [:entry_snapshots, :deliver, :replay, %i[idempotency_key], :owner, STALE_GENERATION, {}],
    [:reference, :show, :probe, %i[none], :requester, OK, {}],
    [:handoff, :settle, :probe, %i[none], :requester, UNAUTHORIZED, {}],
    [:handoff, :stop_applying, :probe, %i[none], :requester, UNAUTHORIZED, {}],
    [:handoff, :drain, :probe, %i[none], :requester, UNAUTHORIZED, {}]
  ].freeze

  # Literal body values the requester's valid requests carry beside its ids.
  ENTRY_BODY = {
    "work_date" => "2026-01-05", "duration" => 60.0, "note" => "tenant guard probe", "source" => "manual",
    "source_metadata" => {}
  }.freeze
  DRAIN_THROUGH = 0

  PATH_PARAM_PATTERN = /\{(\w+)\}/
  COMPANY_PATH_PATTERN = %r{/companies/\d+}

  class << self
    # The requester's own request for the case, built from one company's ids:
    # { company_id:, user_id:, project_id:, agent_id:, entry_ids:, entry_versions:, invoice_id:, operation_id:,
    #   idempotency_key:, generation: }.
    def valid_request(kase, ids:)
      build(kase, request_values(ids))
    end

    # The requester's valid request with only the case's identifier replaced
    # by the owner's.
    def probe_request(kase, requester:, owner:)
      build(kase, swap(kase, request_values(requester), owner))
    end

    # The owner's recorded request with only the company and the
    # Authorization header replaced. A route with no path company (entry
    # snapshot delivery) names its company in each snapshot entry instead.
    def replay_request(recorded, company_id:, authorization:)
      path = recorded.fetch(:path)
      body = recorded.fetch(:body)
      if COMPANY_PATH_PATTERN.match?(path)
        path = path.sub(COMPANY_PATH_PATTERN, "/companies/#{company_id}")
      else
        body = with_snapshot_company(body, company_id)
      end
      recorded.merge(path:, body:, headers: recorded.fetch(:headers).merge("Authorization" => authorization))
    end

    # The case's expected answer with the swapped entry named by the owner's id.
    def expected_answer(kase, owner:)
      resolve_foreign(kase.expected, owner.fetch(:entry_ids).first)
    end

    def frozen_copy(value)
      case value
      when Hash then value.to_h { |key, nested| [frozen_copy(key), frozen_copy(nested)] }.freeze
      when Array then value.map { |nested| frozen_copy(nested) }.freeze
      when String then value.dup.freeze
      else value
      end
    end

    private

      # One entry per request, so a probe's foreign entry is the only entry it names.
      def request_values(ids)
        entry_id = ids.fetch(:entry_ids).first
        ids.slice(:company_id, :user_id, :project_id, :agent_id, :invoice_id, :operation_id, :idempotency_key,
                  :generation)
           .merge(entry_id:, entry_version: ids.fetch(:entry_versions).fetch(entry_id))
      end

      # The reservations key is the body operation_id, so a reservations key
      # swap replaces the operation id.
      def swap(kase, values, owner)
        kind = kase.covers.first
        return values if kind == :none

        kind = :operation_id if kind == :idempotency_key && kase.contract == :reservations
        owner_value = kind == :entry_id ? owner.fetch(:entry_ids).first : owner.fetch(kind)
        values.merge(kind => owner_value)
      end

      def build(kase, values)
        route = TimekeepingContract.load(kase.contract).fetch("routes").fetch(kase.route.to_s)
        {
          method: route.fetch("method"),
          path: route.fetch("path").gsub(PATH_PARAM_PATTERN) { values.fetch(Regexp.last_match(1).to_sym).to_s },
          headers: headers(kase, route, values).merge(kase.headers),
          body: body(kase, values)
        }
      end

      def headers(kase, route, values)
        case kase.contract
        when :entry_api then entry_api_headers(kase, route, values)
        when :entry_snapshots then { "Idempotency-Key" => values.fetch(:idempotency_key) }
        else {}
        end
      end

      def entry_api_headers(kase, route, values)
        return {} if route.fetch("method") == "GET"

        headers = { "Idempotency-Key" => values.fetch(:idempotency_key),
                    "Ownership-Generation" => values.fetch(:generation).to_s }
        return headers unless %i[update destroy].include?(kase.route)

        headers.merge("If-Match" => values.fetch(:entry_version).to_s)
      end

      def body(kase, values)
        case [kase.contract, kase.route]
        in [:entry_api, :create | :update]
          ENTRY_BODY.merge("project_id" => values.fetch(:project_id), "user_id" => values.fetch(:user_id))
        in [:entry_api, :bulk_move]
          { "entry_ids" => [values.fetch(:entry_id)], "project_id" => values.fetch(:project_id) }
        in [:entry_api, :bulk_delete]
          { "entry_ids" => [values.fetch(:entry_id)] }
        in [:reservations, :prepare]
          { "invoice_id" => values.fetch(:invoice_id), "operation_id" => values.fetch(:operation_id),
            "generation" => values.fetch(:generation), "disposition" => "active", "entries" => [values.fetch(:entry_id)] }
        in [:reservations, :commit | :abort]
          { "invoice_id" => values.fetch(:invoice_id), "operation_id" => values.fetch(:operation_id),
            "generation" => values.fetch(:generation) }
        in [:reservations, :mark_billed | :detach_entries]
          { "operation_id" => values.fetch(:operation_id), "generation" => values.fetch(:generation) }
        in [:entry_snapshots, :deliver]
          snapshot_batch(values)
        in [:handoff, :settle | :stop_applying]
          { "generation" => values.fetch(:generation) }
        in [:handoff, :drain]
          { "through" => DRAIN_THROUGH }
        in [:entry_api | :reference, _]
          {}
        end
      end

      # The batch shape comes from TimekeepingSnapshots, so it holds every
      # contract entry field and is not refused before the tenant check.
      def snapshot_batch(values)
        entry = TimekeepingSnapshots.entry(
          id: values.fetch(:entry_id), company_id: values.fetch(:company_id), version: values.fetch(:entry_version),
          project_id: values.fetch(:project_id), user_id: values.fetch(:user_id)
        )
        TimekeepingSnapshots.batch(TimekeepingSnapshots.item(entry, generation: values.fetch(:generation)))
      end

      def with_snapshot_company(body, company_id)
        snapshots = body.fetch("snapshots") do
          raise ArgumentError, "a replayed request names its company in neither its path nor its snapshots"
        end
        body.merge("snapshots" => snapshots.map do |snapshot|
          snapshot.merge("entry" => snapshot.fetch("entry").merge("company_id" => company_id))
        end)
      end

      def resolve_foreign(value, entry_id)
        case value
        when Hash then value.transform_values { |nested| resolve_foreign(nested, entry_id) }
        when Array then value.map { |nested| resolve_foreign(nested, entry_id) }
        when FOREIGN_ENTRY then entry_id
        else value
        end
      end
  end

  # Built after frozen_copy is defined, because Case#initialize calls it.
  ALL = ROWS.map do |contract, route, mode, covers, first, expected, headers|
    Case.new(contract:, route:, mode:, covers:, credential: CREDENTIALS.fetch(contract), first:, expected:, headers:)
  end.freeze
end
