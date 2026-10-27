# frozen_string_literal: true

require "digest"
require "yaml"

module Timekeeping
  # The prepared monolith's entry write path (docs/architecture/timekeeping-soa.md
  # section 10.1): after a rollback from the Timekeeping service, entry writes
  # land in the monolith's own entries, entry_audits, entry_outbox_items and
  # idempotency_records tables, decided by the same shared rules
  # (TimekeepingRules::EntryRules) the service uses.
  #
  # Each call runs in one transaction, in this order:
  #
  # 1. Lock the receipt key (company, actor, operation, key).
  # 2. Read the stored generation FOR SHARE. Any other generation, or any
  #    generation while ownership is not :prepared or a handoff step is set,
  #    is stale_generation. This comes before every other check, so a fenced
  #    request always answers 409, and before the receipt, so a retry at an
  #    old generation is refused even when its earlier answer is stored. The
  #    service writer replays first; this order is deliberately the reverse.
  # 3. Check the request itself: the key, the actor kind, the body's shape,
  #    the credential scan and the field values a snapshot must accept.
  # 4. Replay the stored receipt, or answer idempotency_key_reused.
  # 5. Read the reference facts: the acting user must be a user of the
  #    company, and a named project must be the company's.
  # 6. Lock the target entries FOR UPDATE, by company, in id order, then check
  #    If-Match and the entry rules on the locked rows.
  # 7. Write the entries with version + 1, one audit row per change, one
  #    outbox row per change under the outbox lock, and the receipt last.
  #
  # A refusal at any step writes nothing. checkpoint is called with each name
  # in STEPS as that step finishes, so a spec can fail the transaction at a
  # known point; an error it raises is never rescued here.
  class LocalOwner
    STEPS = %i[
      receipt_key_locked generation_checked request_checked receipt_checked project_checked
      rows_locked rules_checked entry_written audit_written outbox_written receipt_written
    ].freeze

    ENTRY_API = YAML.safe_load_file(Rails.root.join("contracts/timekeeping/entry_api.yml")).freeze
    IDEMPOTENCY = YAML.safe_load_file(Rails.root.join("contracts/timekeeping/idempotency.yml")).freeze

    # Every reason this owner answers with and its status: the contracts'
    # errors, plus this owner's own answers to a request without a key and to
    # a body value the entries table or the projection could not take.
    STATUS = [ENTRY_API, IDEMPOTENCY].flat_map { |contract| contract.fetch("errors").values }
      .to_h { |error| [error.dig("body", "reason").to_sym, error.fetch("status")] }
      .merge(idempotency_key_required: 422, invalid_request: 400)
      .freeze

    RESPONSE_FIELDS = ENTRY_API.dig("response", "entry_fields").freeze
    # The entry fields a body may set. user_id names the target user and is
    # decided by the rules; project_id is checked against the reference facts.
    WRITABLE_FIELDS = (ENTRY_API.dig("request", "entry_required_fields") +
                       ENTRY_API.dig("request", "entry_optional_fields") - %w[user_id]).freeze
    # Checked through Timekeeping::SnapshotBatch's casts, so no committed
    # snapshot can be one the projection refuses: the relay delivers in order,
    # so one refused snapshot would hold back every later one.
    CAST_FIELDS = (WRITABLE_FIELDS - %w[project_id]).freeze
    CREATE_REQUIRED_FIELDS = %w[work_date duration].freeze
    # A snapshot carries the entry three levels down, and the projection
    # parses a batch with JSON's default limit of 100 levels.
    BODY_MAX_NESTING = 97

    ACTOR_TYPE = "user"
    UNBILLED = "unbilled"
    ID = TimekeepingRules::EntryDecision::ID
    KEY_SEPARATOR = "\u001F"
    # The one key every writer of entry_outbox_items takes just before its
    # inserts and holds until commit, so outbox positions commit in the order
    # they were drawn and the relay never passes a position still uncommitted.
    OUTBOX_LOCK_KEY = 2_026_034_001

    ROUTE_WRITERS = {
      create: :create_entry,
      update: :update_entry,
      destroy: :destroy_entry,
      bulk_move: :bulk_change,
      bulk_delete: :bulk_change
    }.freeze
    PROJECT_ROUTES = { create: :required, update: :optional, bulk_move: :required }.freeze
    ENTRY_ROUTES = %i[update destroy].freeze
    BULK_ROUTES = %i[bulk_move bulk_delete].freeze
    BULK_ACTIONS = { bulk_move: :move, bulk_delete: :delete }.freeze
    BULK_RESULTS = { bulk_move: "moved", bulk_delete: "deleted" }.freeze
    NOT_FOUND_RESULT = "not_found"

    # What a write answers: an HTTP status and a JSON-ready body with string
    # keys. A replayed receipt answers the body parsed from the stored text,
    # so every body is built to survive that round trip unchanged.
    Outcome = Data.define(:status, :body) do
      def self.refusal(reason)
        new(status: STATUS.fetch(reason), body: { "reason" => reason.to_s })
      end

      def self.success(status, payload)
        new(status:, body: JSON.parse(JSON.generate(payload)))
      end
    end

    # The entries a route changed, the status to answer with, and how to build
    # the answer from the changed rows as committed.
    Written = Data.define(:status, :changes, :payload)
    # One changed entry and its stored values before the change; before is
    # nil for a create.
    Change = Data.define(:entry_id, :before)

    # The receipt and audit tables have no other model in the monolith.
    class Receipt < ApplicationRecord
      self.table_name = "idempotency_records"
    end

    class AuditRow < ApplicationRecord
      self.table_name = "entry_audits"
    end

    def self.call(operation:, company_id:, generation:, actor:, params:, checkpoint: ->(_step) { })
      new(operation:, company_id:, generation:, actor:, params:, checkpoint:).call
    end

    # :reek:LongParameterList
    def initialize(operation:, company_id:, generation:, actor:, params:, checkpoint:)
      @operation = operation.to_sym
      raise ArgumentError, "unknown operation #{operation.inspect}" unless ROUTE_WRITERS.key?(@operation)

      @company_id = company_id
      @generation = generation
      @actor = actor
      @params = params
      @checkpoint = checkpoint
      @today = Date.current
    end

    # Raised only when the receipt insert hits the unique index, so a
    # uniqueness error from anywhere else, a checkpoint included, is never
    # mistaken for a receipt another writer committed.
    class ReceiptTaken < ActiveRecord::RecordNotUnique; end

    def call
      attempt
    rescue ReceiptTaken
      # A backstop: the receipt-key lock normally stops two writers with one
      # key from both reaching the insert. The failed attempt has rolled back
      # every row it wrote. Running the steps again checks the generation
      # first and then replays the receipt that now exists.
      attempt
    end

    private

      attr_reader :operation, :company_id, :generation, :actor, :params, :checkpoint, :today

      # Each attempt runs in its own savepoint, so a failure rolls back this
      # write even when the caller has a transaction open and rescues the error.
      def attempt
        ApplicationRecord.transaction(requires_new: true) { write }
      end

      def write
        lock_receipt_key unless key.empty?
        checkpoint.call(:receipt_key_locked)
        stored_generation = admitted_generation
        refusal = admission_refusal(stored_generation)
        return refusal if refusal

        receipt = find_receipt
        checkpoint.call(:receipt_checked)
        return answer_from(receipt) if receipt

        write_change(stored_generation)
      end

      # The generation fence, then the checks on the request itself. Both come
      # before the receipt, so a fenced or malformed request is never replayed.
      def admission_refusal(stored_generation)
        return Outcome.refusal(:stale_generation) unless generation_matches?(stored_generation)

        checkpoint.call(:generation_checked)
        refusal = request_refusal
        return Outcome.refusal(refusal) if refusal

        checkpoint.call(:request_checked)
        nil
      end

      def write_change(stored_generation)
        facts = reference_facts
        acting = facts && facts[:users].find { |user| user[:id] == actor.user_id }
        return Outcome.refusal(:not_found) unless acting && project_known?(facts)

        checkpoint.call(:project_checked)
        written = send(ROUTE_WRITERS.fetch(operation), facts, acting[:role])
        return written if written.is_a?(Outcome)

        commit_change(written, stored_generation)
      end

      def commit_change(written, stored_generation)
        checkpoint.call(:entry_written)
        rows = reserved_rows(written.changes.map(&:entry_id))
        write_audit(written.changes, rows)
        checkpoint.call(:audit_written)
        write_outbox(written.changes.map { |change| rows.fetch(change.entry_id) }, stored_generation)
        checkpoint.call(:outbox_written)
        outcome = Outcome.success(written.status, written.payload.call(rows))
        store_receipt(outcome)
        checkpoint.call(:receipt_written)
        outcome
      end

      # Request values. Only these keys of params are read, so a company_id
      # or actor field elsewhere in params or in the body changes nothing.

      def key
        params["idempotency_key"].to_s.strip
      end

      def body
        params.fetch("body", nil) || {}
      end

      def request_operation
        "#{operation} #{target_id}"
      end

      def fingerprint
        Digest::SHA256.hexdigest(JSON.generate(body))
      end

      def target_id
        Integer(params["entry_id"].to_s, 10) if ENTRY_ROUTES.include?(operation) && ID.match?(params["entry_id"].to_s)
      end

      # nil when the route names no project, :invalid when the body's
      # project_id is missing where required or is not an id. Either way it is
      # answered as not found, as another company's project is.
      def project_id
        requirement = PROJECT_ROUTES[operation]
        return if requirement.nil? || (requirement == :optional && !body.key?("project_id"))

        id_value(body["project_id"]) || :invalid
      end

      # A positive Integer, or a string of digits read as one; nil otherwise.
      def id_value(value)
        return value if value.is_a?(Integer) && value.positive?

        Integer(value, 10) if value.is_a?(String) && ID.match?(value)
      end

      # Generation

      # The one generation this owner admits, read FOR SHARE so a handoff that
      # updates the row waits for this write to commit. nil while the monolith
      # is not the prepared owner, during a handoff, or when the row is missing.
      def admitted_generation
        ownership = TimekeepingOwnership.lock("FOR SHARE").find_by(id: TimekeepingOwnership::SINGLETON_ID)
        return if ownership.nil? || !ownership.handoff_step.nil? || EntryOwner.for(ownership) != :prepared

        ownership.generation
      end

      # nil matches nothing, and a sent value that is not a plain integer
      # never matches, so neither a missing header nor "abc" can be admitted.
      def generation_matches?(stored_generation)
        !stored_generation.nil? && ID.match?(generation.to_s) && Integer(generation.to_s, 10) == stored_generation
      end

      # Request checks

      def request_refusal
        return :idempotency_key_required if key.empty?
        # Timekeeping's entry API admits only user actors.
        return :forbidden unless actor.user?
        return :invalid_request unless body.is_a?(Hash) && !too_deep?(body, 1)
        return :credential_in_body if credential_in_body?

        :invalid_request unless valid_fields?
      end

      # Stops descending once past the limit, so a hostile body cannot exhaust
      # the stack here or in the credential scan that follows.
      def too_deep?(value, depth)
        return true if depth > BODY_MAX_NESTING

        children = value.is_a?(Hash) ? value.values : value
        children.any? { |child| (child.is_a?(Hash) || child.is_a?(Array)) && too_deep?(child, depth + 1) }
      end

      def credential_in_body?
        TimekeepingRules::CredentialScan.found?(
          body,
          held_token: ENV.fetch(Internal::V1::BaseController::SERVICE_TOKEN_ENV, nil),
          public_key: token_public_key
        )
      end

      # The public half of the key the monolith signs user tokens with. An
      # unset or unreadable key is not held, so it matches nothing.
      def token_public_key
        UserToken.private_key_from_env.public_key
      rescue UserToken::MissingKeyError
        nil
      end

      # A field is checked only when the body sends it: an absent field keeps
      # its stored value, or the column default on a create.
      def valid_fields?
        return false if operation == :create && !CREATE_REQUIRED_FIELDS.all? { |field| body.key?(field) }
        return false if BULK_ROUTES.include?(operation) && !body["entry_ids"].is_a?(Array)
        # The snapshot cast reads any ISO 8601 date; the entry API takes only YYYY-MM-DD.
        return false if body.key?("work_date") && !TimekeepingRules::EntryDecision::DATE.match?(body["work_date"].to_s)

        # A cast raises InvalidValue for a value it refuses; its result is not needed.
        CAST_FIELDS.each { |field| SnapshotBatch::FIELD_CASTS.fetch(field).call(body[field]) if body.key?(field) }
        true
      rescue SnapshotBatch::InvalidValue
        false
      end

      # Receipts

      # Only writers with the same company, actor, operation and key wait on
      # each other. The lock is taken on two signed 32-bit keys from a digest
      # of those parts; rows are always read by their columns.
      def lock_receipt_key
        advisory_lock(*Digest::SHA256.digest(
          [company_id, ACTOR_TYPE, actor.user_id || actor.name, request_operation, key].join(KEY_SEPARATOR)
        ).unpack("l>l>"))
      end

      def find_receipt
        Receipt.find_by(company_id:, actor_type: ACTOR_TYPE, actor_id: actor.user_id, operation: request_operation, key:)
      end

      def answer_from(receipt)
        return Outcome.refusal(:idempotency_key_reused) unless receipt.fingerprint == fingerprint

        Outcome.new(status: receipt.status, body: JSON.parse(receipt.body))
      end

      def store_receipt(outcome)
        Receipt.create!(
          company_id:, actor_type: ACTOR_TYPE, actor_id: actor.user_id, operation: request_operation, key:,
          fingerprint:, status: outcome.status, body: JSON.generate(outcome.body), created_at: Time.current
        )
      rescue ActiveRecord::RecordNotUnique => error
        raise ReceiptTaken, error.message
      end

      # Reference facts

      # The reference facts, plus the acting user's primary role: their
      # lowest-id role in the company, which decides A6 and A7 as the
      # monolith's own locked and billed checks do. The role in the facts may
      # be a raised owner or admin role, so it never unlocks those rules.
      def reference_facts
        company = Company.find_by(id: company_id)
        return if company.nil?

        ReferenceFacts.call(company:, project_ids: [project_id].grep(Integer))
          .merge(primary_role: User.primary_roles_for(company, [actor.user_id]).fetch(actor.user_id))
      end

      def project_known?(facts)
        id = project_id
        return false if id == :invalid

        id.nil? || facts[:projects].any? { |project| project[:id] == id }
      end

      # Route writers

      def create_entry(facts, role)
        checkpoint.call(:rows_locked)
        user_id = target_user_id(facts, role)
        return user_id if user_id.is_a?(Outcome)
        return Outcome.refusal(:not_found) unless agent_owned?(facts, body["agent_id"], user_id)

        checkpoint.call(:rules_checked)
        entry = LocalEntry.create!(entry_fields.merge(
          "company_id" => company_id, "user_id" => user_id, "bill_status" => body["bill_status"] || UNBILLED,
          "review_status" => TimekeepingRules::EntryRules.created_review_status(agent_id: body["agent_id"])
        ))
        Written.new(status: 201, changes: [Change.new(entry_id: entry.id, before: nil)],
                    payload: ->(rows) { response_body(rows.fetch(entry.id)) })
      end

      def update_entry(facts, role)
        entry = locked_entries([target_id].compact, role).first
        checkpoint.call(:rows_locked)
        return Outcome.refusal(:not_found) unless entry
        return Outcome.refusal(:version_conflict) unless version_matches?(entry)

        refusal = change_refusal(entry, facts, role, action: :update, bill_status: body["bill_status"])
        return refusal if refusal

        fields = entry_fields
        if body.key?("user_id")
          user_id = target_user_id(facts, role)
          return user_id if user_id.is_a?(Outcome)

          fields["user_id"] = user_id
        end
        committed = stored_values(entry).merge(fields)
        return Outcome.refusal(:not_found) unless agent_owned?(facts, committed["agent_id"], committed["user_id"])

        checkpoint.call(:rules_checked)
        single_change(entry, fields)
      end

      # S7 on the agent and user the row will hold. The projection refuses any
      # other pairing, and the relay delivers in order, so one refused snapshot
      # would hold back every later one. Checked on every create and update,
      # so a stored agent that has since moved to another user is caught too.
      def agent_owned?(facts, agent_id, user_id)
        company_agents = facts[:agents].to_h { |agent| [agent[:id], agent[:user_id]] }
        TimekeepingRules::EntryRules.agent_owner(agent_id:, user_id:, company_agents:) == :ok
      end

      def destroy_entry(facts, role)
        entry = locked_entries([target_id].compact, role).first
        checkpoint.call(:rows_locked)
        return Outcome.refusal(:not_found) unless entry
        return Outcome.refusal(:version_conflict) unless version_matches?(entry)

        refusal = change_refusal(entry, facts, role, action: :delete, bill_status: nil)
        return refusal if refusal

        checkpoint.call(:rules_checked)
        single_change(entry, "discarded_at" => Time.current)
      end

      # Targets are only the entries the caller may see; any other id, from
      # another company, a colleague's entry for an employee, a discarded entry
      # or one that is not an id at all, is reported as not_found and takes no
      # part in the decision. A skipped entry is reported the same way.
      def bulk_change(facts, role)
        entries = locked_entries(body.fetch("entry_ids").filter_map { |id| id_value(id) }.uniq, role,
                                 visible_only: true)
        checkpoint.call(:rows_locked)
        decision = TimekeepingRules::EntryDecision.bulk(
          action: BULK_ACTIONS.fetch(operation), role:, primary_role: facts[:primary_role], acting_user_id: actor.user_id,
          entries: entries.map { |entry| rule_facts(entry) }, edit_days: facts[:edit_days], today:
        )
        return Outcome.refusal(:forbidden) if decision == :forbidden

        checkpoint.call(:rules_checked)
        fields = operation == :bulk_move ? { "project_id" => project_id } : { "discarded_at" => Time.current }
        applied = entries.select { |entry| decision.fetch(entry.id) == :apply }
        changes = applied.map { |entry| apply_change(entry, fields) }
        Written.new(status: 200, changes:, payload: ->(_rows) { bulk_results(applied.map(&:id)) })
      end

      def bulk_results(applied_ids)
        result = BULK_RESULTS.fetch(operation)
        results = body.fetch("entry_ids").map do |id|
          { "entry_id" => id, "result" => applied_ids.include?(id_value(id)) ? result : NOT_FOUND_RESULT }
        end
        { "results" => results }
      end

      # The body's writable fields, with project_id as the checked Integer.
      def entry_fields
        fields = body.slice(*WRITABLE_FIELDS)
        fields["project_id"] = project_id if fields.key?("project_id")
        fields
      end

      def single_change(entry, fields)
        change = apply_change(entry, fields)
        Written.new(status: 200, changes: [change], payload: ->(rows) { response_body(rows.fetch(entry.id)) })
      end

      def apply_change(entry, fields)
        before = stored_values(entry)
        entry.update!(fields.merge("version" => entry.version + 1))
        Change.new(entry_id: entry.id, before:)
      end

      # Locks the company's kept entries with these ids in id order, so two
      # writers over the same entries wait in turn and never deadlock. The
      # reservation flag is read in a second statement once the locks are
      # held: a statement that waited on a lock still evaluates its subquery
      # against the snapshot taken before the wait.
      def locked_entries(ids, role, visible_only: false)
        relation = LocalEntry.where(company_id:, id: ids, discarded_at: nil)
        if visible_only
          scope = TimekeepingRules::EntryRules.visible_scope(role:, acting_user_id: actor.user_id)
          relation = relation.where(user_id: scope) unless scope == :company
        end
        locked_ids = relation.order(:id).lock("FOR UPDATE").pluck(:id)
        reserved_rows(locked_ids).values_at(*locked_ids)
      end

      # The company's entries with these ids as stored now, discarded ones
      # included, each with the reservation flag, keyed by id.
      def reserved_rows(entry_ids)
        LocalEntry.with_reserved.where(company_id:, id: entry_ids).index_by(&:id)
      end

      def version_matches?(entry)
        TimekeepingRules::EntryDecision.version(if_match: params["if_match"], current_version: entry.version) == :ok
      end

      def change_refusal(entry, facts, role, action:, bill_status:)
        decision = TimekeepingRules::EntryDecision.change(
          action:, bill_status:, role:, primary_role: facts[:primary_role], acting_user_id: actor.user_id,
          entry: rule_facts(entry), edit_days: facts[:edit_days], today:
        )
        Outcome.refusal(decision) unless decision == :ok
      end

      def rule_facts(entry)
        { id: entry.id, user_id: entry.user_id, work_date: entry.work_date, bill_status: entry.bill_status,
          locked: entry.reserved }
      end

      # The body's user_id resolved against the company's users from the
      # reference facts: the acting user when it is missing or names them.
      def target_user_id(facts, role)
        requested = body["user_id"]
        decision = TimekeepingRules::EntryDecision.target_user(
          acting_user_id: actor.user_id, role:, requested_user_id: requested,
          company_user_ids: facts[:users].pluck(:id)
        )
        case decision
        when :acting then actor.user_id
        when :requested then Integer(requested.to_s, 10)
        else Outcome.refusal(decision)
        end
      end

      # Audit and outbox

      def stored_values(entry)
        entry.attributes.except("reserved")
      end

      def write_audit(changes, rows)
        now = Time.current
        changes.each do |change|
          row = rows.fetch(change.entry_id)
          AuditRow.create!(
            company_id:, entry_id: change.entry_id, action: operation.to_s, actor_type: ACTOR_TYPE,
            actor_id: actor.user_id, before: change.before, after: stored_values(row),
            entry_created_at: row.created_at, created_at: now
          )
        end
      end

      def write_outbox(rows, stored_generation)
        return if rows.empty?

        advisory_lock(OUTBOX_LOCK_KEY)
        now = Time.current
        LocalOutboxEntry.insert_all!(rows.map do |row|
          { company_id:, entry_id: row.id, generation: stored_generation, payload: snapshot(row), created_at: now }
        end)
      end

      # The contract snapshot of one entry, read with the reservation flag:
      # locked is that flag, never the stored entries.locked column.
      def snapshot(row)
        json_fields(row, SnapshotBatch::ENTRY_FIELDS)
      end

      def response_body(row)
        json_fields(row, RESPONSE_FIELDS)
      end

      def json_fields(row, fields)
        fields.index_with { |field| json_value(field == "locked" ? row.reserved : row[field]) }
      end

      # Times as UTC with microseconds, the precision the column stores, and
      # dates as ISO 8601; every other value, a Float duration included, as is.
      def json_value(value)
        case value
        when Time, ActiveSupport::TimeWithZone then value.utc.iso8601(6)
        when Date then value.iso8601
        else value
        end
      end

      def advisory_lock(*keys)
        placeholders = Array.new(keys.size, "?").join(", ")
        ApplicationRecord.connection.execute(
          ApplicationRecord.sanitize_sql_array(["SELECT pg_advisory_xact_lock(#{placeholders})", *keys])
        )
      end
  end
end
