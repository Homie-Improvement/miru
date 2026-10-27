# frozen_string_literal: true

require_relative "client"
require_relative "contract"
require_relative "monolith_arrange"

module TimekeepingContract
  # Drives Timekeeping::LocalOwner from the shared entry API examples. The
  # gateway, not LocalOwner, knows who is signed in, so this client stands in
  # for it: it verifies the bearer token, maps the route, token and headers to
  # LocalOwner.call's keywords, and answers the read routes and 401 itself.
  # Token handling lives only here, in spec support; production code never
  # takes a token in place of the gateway's user.
  class LocalOwnerClient
    ENTRY_API = TimekeepingContract.load(:entry_api)
    READ_ROUTES = %w[show index].freeze

    def initialize(public_key:)
      @public_key = public_key
      @router = Router.new(ENTRY_API.fetch("routes"))
    end

    def call(method, path, headers: {}, body: nil)
      headers = headers.to_h
      route, params = @router.match(method, path)
      return Wire.error(ENTRY_API, "not_found") unless route

      claims = verified_claims(headers)
      return Wire.error(ENTRY_API, "unauthorized") unless claims
      # The gateway acts in the signed-in user's company only.
      return Wire.error(ENTRY_API, "not_found") unless params["company_id"] == claims.company_id.to_s

      READ_ROUTES.include?(route) ? read(route, claims, params) : write(route, claims, params, headers, body)
    end

    private

      def verified_claims(headers)
        token = Wire.bearer(headers)
        token && Timekeeping::UserToken.verify(token, public_key: @public_key)
      rescue Timekeeping::UserToken::InvalidTokenError
        nil
      end

      def write(route, claims, params, headers, body)
        outcome = Timekeeping::LocalOwner.call(
          operation: route.to_sym,
          company_id: claims.company_id,
          generation: headers["Ownership-Generation"],
          actor: Timekeeping::LocalOwner::Actor.user(user_id: claims.user_id, role: claims.role),
          params: {
            "idempotency_key" => headers["Idempotency-Key"],
            "if_match" => headers["If-Match"],
            "entry_id" => params["entry_id"],
            "body" => Wire.copy(body)
          }
        )
        Response.new(status: outcome.status, body: Wire.copy(outcome.body))
      end

      def read(route, claims, params)
        entries = visible_entries(claims)
        if route == "show"
          entry = entries.find_by(id: Integer(params["entry_id"], 10, exception: false))
          return entry ? Response.new(status: 200, body: present(entry)) : Wire.error(ENTRY_API, "not_found")
        end

        Response.new(status: 200, body: { "entries" => filtered(entries, params).order(:id).map { |entry| present(entry) } })
      end

      # The company's kept entries the reader may see, by the shared A1 rule.
      def visible_entries(claims)
        relation = Timekeeping::LocalEntry.with_reserved.where(company_id: claims.company_id, discarded_at: nil)
        scope = TimekeepingRules::EntryRules.visible_scope(role: claims.role, acting_user_id: claims.user_id)
        scope == :company ? relation : relation.where(user_id: scope)
      end

      def filtered(entries, params)
        entries = entries.where(user_id: Integer(params["user_id"], 10)) if params["user_id"].present?
        entries = entries.where(project_id: Integer(params["project_id"], 10)) if params["project_id"].present?
        entries = entries.where(work_date: Date.iso8601(params["from"])..) if params["from"].present?
        entries = entries.where(work_date: ..Date.iso8601(params["to"])) if params["to"].present?
        entries
      end

      # The contract response fields, as LocalOwner answers them after a write.
      def present(entry)
        fields = Timekeeping::LocalOwner::RESPONSE_FIELDS.index_with do |field|
          value = field == "locked" ? entry.reserved : entry[field]
          value.is_a?(Date) ? value.iso8601 : value
        end
        Wire.copy(fields)
      end
  end

  # The timekeeping_arrange for the local owner. Companies, users, projects and
  # tokens come from MonolithArrange; entries and reservations are seeded
  # straight into the prepared tables LocalOwner writes. Ownership is put in
  # the prepared monolith, so LocalOwner admits writes at its generation.
  class LocalOwnerArrange
    ENTRY_DEFAULTS = { "work_date" => "2026-03-02", "duration" => 60.0, "bill_status" => "unbilled" }.freeze

    delegate :company, :user, :project, :token_for, :current_generation, :set_generation, :begin_handoff,
             :flip_ownership, :projected_entry, to: :@monolith

    def initialize(private_key:)
      @monolith = MonolithArrange.new(private_key:)
      TimekeepingOwnership.current.update!(owner: "monolith", monolith_store: "prepared", handoff_step: nil)
    end

    # The local owner holds one service credential, TIMEKEEPING_SERVICE_TOKEN,
    # and scans entry bodies for it, so that is the identity handed out.
    def service_identity(company:, name:, operations:)
      ENV.fetch(Internal::V1::BaseController::SERVICE_TOKEN_ENV)
    end

    # An agent row of the company that belongs to user. Validations are
    # skipped because the contract also builds an agent for a user outside
    # its company, to prove the owner refuses it.
    def agent(company:, user:)
      FactoryBot.build(:agent, company_id: company, user_id: user).tap { |agent| agent.save!(validate: false) }.id
    end

    def entry(company:, user:, project:, **attributes)
      Timekeeping::LocalEntry.create!(
        ENTRY_DEFAULTS.merge(attributes.transform_keys(&:to_s), "company_id" => company, "user_id" => user,
                                                                "project_id" => project)
      ).id
    end

    # An entry that already holds a reservation, without the reservation
    # routes, which this owner does not serve yet.
    def reserved_entry(company:, invoice_id:, state: "committed", disposition: "active", **attributes)
      entry_id = entry(company:, user: user(company:, role: "employee"), project: project(company:), **attributes)
      ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql_array([<<~SQL.squish, company, entry_id, invoice_id, SecureRandom.uuid, state, disposition]))
        INSERT INTO reservations (company_id, entry_id, invoice_id, operation_id, state, disposition, created_at)
        VALUES (?, ?, ?, ?, ?, ?, NOW())
      SQL
      entry_id
    end

    def reservations_for(entry_id)
      ApplicationRecord.connection.select_all(ApplicationRecord.sanitize_sql_array([<<~SQL.squish, entry_id]))
        SELECT invoice_id, state FROM reservations WHERE entry_id = ? ORDER BY created_at
      SQL
        .to_a
    end

    # The entry's stored snapshot fields, with locked as the reservation flag.
    def stored_entry(entry_id)
      entry = Timekeeping::LocalEntry.with_reserved.find(entry_id)
      fields = Timekeeping::SnapshotBatch::ENTRY_FIELDS.index_with do |field|
        value = field == "locked" ? entry.reserved : entry[field]
        case value
        when Time, ActiveSupport::TimeWithZone then value.utc.iso8601(6)
        when Date then value.iso8601
        else value
        end
      end
      Wire.copy(fields)
    end

    def entry_locked(entry_id)
      Timekeeping::LocalEntry.with_reserved.find(entry_id).reserved
    end

    # Every outbox row, sent or not.
    def outbox_size
      Timekeeping::LocalOutboxEntry.count
    end

    # The unsent outbox rows in position order, each with its snapshot.
    def published_snapshots
      Timekeeping::LocalOutboxEntry.where(sent_at: nil).order(:outbox_position).map do |row|
        { "generation" => row.generation, "outbox_position" => row.outbox_position, "entry" => row.payload }
      end
    end
  end
end
