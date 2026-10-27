# frozen_string_literal: true

require "digest"

module Timekeeping
  # One entry write, checked and ready for Timekeeping::EntryWriter. Building
  # it checks the input, refuses a body that holds a credential and reads the
  # reference facts, all before any transaction opens. It makes no
  # authorization decision: who may change what is decided by the writer on
  # the locked rows.
  #
  # route is one of :create, :update, :destroy, :bulk_move, :bulk_delete.
  class EntryCommand < Data.define(:route, :company_id, :actor_id, :role, :primary_role, :entry_id, :operation, :key,
                                   :fingerprint, :body, :project_id, :generation, :if_match, :facts, :today,
                                   :replay_only)
    ID = /\A[0-9]{1,19}\z/
    ACTOR_TYPE = "user"
    UNBILLED = "unbilled"

    # The entry fields a body may set: entry_required_fields and
    # entry_optional_fields of contracts/timekeeping/entry_api.yml, less
    # user_id, which names the target user and is decided by the writer.
    WRITABLE_FIELDS = %w[project_id work_date duration note source source_metadata bill_status agent_id proof_url
                         proof_metadata].freeze

    # The shape each field must have when the body sends it, so a value the
    # entries table or the projection cannot store is refused as a bad request
    # rather than failing inside the transaction or holding back snapshot
    # delivery. project_id is not here: parse_project_id reads it, and accepts
    # a decimal string the snapshot rule would refuse.
    FIELD_SHAPES = SnapshotValues::RULES.slice(
      *%w[work_date duration note source source_metadata bill_status agent_id proof_url proof_metadata]
    ).freeze
    CREATE_REQUIRED_FIELDS = %w[work_date duration].freeze

    # The deepest body accepted: the body object itself plus metadata as deep
    # as a snapshot may carry it.
    BODY_MAX_NESTING = SnapshotValues::METADATA_MAX_NESTING + 1

    # The routes whose body names a project, and whether it must.
    PROJECT_ROUTES = { create: :required, update: :optional, bulk_move: :required }.freeze
    ENTRY_ROUTES = %i[update destroy].freeze
    BULK_ROUTES = %i[bulk_move bulk_delete].freeze

    # A DELETE carrying this header and value is answered only from its stored
    # receipt (contracts/timekeeping/entry_api.yml rules.replay_only). It lets a
    # caller whose own lookup no longer finds the entry reach the answer of a
    # delete that already committed, without ever running a new delete. Every
    # other route, and any other value, is an ordinary write.
    REPLAY_HEADER = "Idempotency-Replay"
    REPLAY_ONLY_VALUE = "only"
    REPLAY_ROUTES = %i[destroy].freeze

    # Returns an EntryCommand, or the Timekeeping::WriteOutcome that refuses
    # the request. Raises ActionController::BadRequest for a body that is not
    # a JSON object or holds a value of the wrong shape.
    def self.build(route:, identity:, bearer:, company_id:, entry_id:, headers:, raw_body:, reference_client:,
                   today: Date.current)
      key = headers["Idempotency-Key"].to_s
      # Every committed change carries its receipt, so a write without a key,
      # whose retry could not be recognised, is never evaluated.
      return WriteOutcome.refusal(:idempotency_key_required) if key.strip.empty?

      body = parse_body(raw_body)
      if CredentialScan.found?(body, bearer:, held: Timekeeping.config.service_credentials,
                                     public_key: Environment.token_public_key)
        return WriteOutcome.refusal(:credential_in_body)
      end

      target_id = parse_entry_id(route, entry_id)
      return WriteOutcome.refusal(:not_found) if ENTRY_ROUTES.include?(route) && target_id.nil?

      project_id = parse_project_id(route, body)
      return WriteOutcome.refusal(:not_found) if project_id == :invalid

      check_fields!(route, body)
      project_ids = [project_id].compact
      facts = reference_client.fetch(company_id:, project_ids:)

      new(
        route:, company_id:, actor_id: identity.user_id, role: identity.role, primary_role: identity.primary_role,
        entry_id: target_id,
        operation: "#{route} #{target_id}", key:, fingerprint: Digest::SHA256.hexdigest(JSON.generate(body)),
        body:, project_id:, generation: headers["Ownership-Generation"], if_match: headers["If-Match"], facts:, today:,
        replay_only: replay_only?(route, headers)
      )
    rescue ReferenceClient::Unavailable
      WriteOutcome.refusal(:reference_unavailable)
    end

    # The body's writable fields, with project_id as the checked Integer.
    def entry_fields
      fields = body.slice(*WRITABLE_FIELDS)
      fields["project_id"] = project_id if fields.key?("project_id")
      fields
    end

    def bill_status_default
      body["bill_status"] || UNBILLED
    end

    # The body as a Hash. Timekeeping::ReservationRequest reads its bodies
    # the same way.
    def self.parse_body(raw_body)
      return {} if raw_body.to_s.strip.empty?

      body = JSON.parse(raw_body, max_nesting: BODY_MAX_NESTING)
      raise ActionController::BadRequest, "the body must be a JSON object" unless body.is_a?(Hash)

      body
    rescue JSON::NestingError
      raise ActionController::BadRequest, "the body is nested too deeply"
    rescue JSON::ParserError
      raise ActionController::BadRequest, "the body is not JSON"
    end

    def self.parse_entry_id(route, value)
      Integer(value.to_s, 10) if ENTRY_ROUTES.include?(route) && ID.match?(value.to_s)
    end

    # nil when the route names no project, :invalid when the body's project_id
    # is missing where required or is not an id. Either way the project is
    # answered as not found, as a project of another company is.
    def self.parse_project_id(route, body)
      requirement = PROJECT_ROUTES[route]
      return if requirement.nil? || (requirement == :optional && !body.key?("project_id"))

      value = body["project_id"]
      return value if value.is_a?(Integer) && value.positive?
      return Integer(value, 10) if value.is_a?(String) && ID.match?(value)

      :invalid
    end

    def self.replay_only?(route, headers)
      REPLAY_ROUTES.include?(route) && headers[REPLAY_HEADER].to_s == REPLAY_ONLY_VALUE
    end

    def self.check_fields!(route, body)
      if route == :create && !CREATE_REQUIRED_FIELDS.all? { |field| body.key?(field) }
        raise ActionController::BadRequest, "a create needs #{CREATE_REQUIRED_FIELDS.join(" and ")}"
      end
      if BULK_ROUTES.include?(route) && !body["entry_ids"].is_a?(Array)
        raise ActionController::BadRequest, "entry_ids must be a list"
      end

      invalid = FIELD_SHAPES.select { |field, valid| body.key?(field) && !valid.call(body[field]) }.keys
      raise ActionController::BadRequest, "invalid #{invalid.join(", ")}" unless invalid.empty?
    end

    private_class_method :parse_entry_id, :parse_project_id, :replay_only?, :check_fields!
  end
end
