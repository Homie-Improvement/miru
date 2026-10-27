# frozen_string_literal: true

module Timekeeping
  # Carries out one Timekeeping::EntryCommand in a single transaction, so the
  # entry change, its audit rows, its outbox snapshots and its idempotency
  # receipt commit together or not at all. The steps, in order:
  #
  # 1. Lock the receipt key and re-read the receipt: a stored answer for the
  #    same body is replayed, and a different body is idempotency_key_reused.
  #    A replay-only command with no receipt answers not_found here, before
  #    any later step, so it can never write.
  # 2. Read the admitted generation FOR SHARE; a header that is not that
  #    generation, or any header while fenced, is stale_generation. A project
  #    the reference facts do not hold for the company is not_found. Both come
  #    after the receipt, so a retry of a committed write replays even if they
  #    have changed, or Timekeeping has been fenced since.
  # 3. Lock the target entries FOR UPDATE, by company (and the A1 scope on
  #    bulk routes), in id order, so two writers over the same entries wait in
  #    turn and never deadlock.
  # 4. Check If-Match and the entry rules on the locked rows, and that the
  #    agent the write commits is one of the company's agents for its user.
  # 5. Write the entries with version + 1 and one audit row per change.
  # 6. Under the outbox lock, insert one outbox snapshot per change.
  # 7. Insert the receipt.
  #
  # checkpoint is called with the name of each step as it finishes, so a spec
  # can hold a transaction at a known point or fail it after a given insert.
  # The generation is read from Timekeeping::Admission; the locks, audit and
  # outbox steps are Timekeeping::WriteSteps.
  class EntryWriter
    BULK_RESULTS = { bulk_move: "moved", bulk_delete: "deleted" }.freeze
    BULK_ACTIONS = { bulk_move: :move, bulk_delete: :delete }.freeze
    NOT_FOUND_RESULT = "not_found"

    # The entries a route changed, the status to answer with and how to build
    # the answer from the changed rows as committed.
    Written = Data.define(:status, :changes, :payload)
    # One changed entry and its stored values before the change; before is nil
    # for a create.
    Change = Data.define(:entry_id, :before)

    ROUTE_WRITERS = {
      create: :create_entry,
      update: :update_entry,
      destroy: :destroy_entry,
      bulk_move: :bulk_change,
      bulk_delete: :bulk_change
    }.freeze

    def initialize(checkpoint: ->(_step) { })
      @checkpoint = checkpoint
    end

    def call(command)
      ApplicationRecord.transaction { write(command) }
    rescue ActiveRecord::RecordNotUnique
      # A backstop: the receipt-key lock normally stops two writers with one
      # key from both reaching the insert. The failed transaction has rolled
      # back every row it wrote, so the stored receipt decides the answer.
      receipt = find_receipt(command)
      raise unless receipt

      answer_from(receipt, command)
    rescue WriteSteps::UnpublishableRows => error
      # A stored row the projection would refuse. The transaction has rolled
      # back the entry change, its audit rows and the receipt, so a retry is
      # checked again against what is stored then.
      error.outcome
    end

    private

      attr_reader :checkpoint

      def write(command)
        lock_receipt_key(command)
        receipt = find_receipt(command)
        checkpoint.call(:receipt_checked)
        return answer_from(receipt, command) if receipt
        return WriteOutcome.refusal(:not_found) if command.replay_only

        generation = locked_generation
        checkpoint.call(:generation_checked)
        unless WriteSteps.generation_matches?(command.generation, generation)
          return WriteOutcome.refusal(:stale_generation)
        end
        return WriteOutcome.refusal(:not_found) unless project_known?(command)

        written = send(ROUTE_WRITERS.fetch(command.route), command)
        return written if written.is_a?(WriteOutcome)

        commit_change(command, written, generation)
      end

      def commit_change(command, written, generation)
        checkpoint.call(:entry_written)
        rows = WriteSteps.reserved_rows(command.company_id, written.changes.map(&:entry_id))
        write_audit(command, written.changes, rows)
        checkpoint.call(:audit_written)
        WriteSteps.write_outbox(written.changes.map { |change| rows.fetch(change.entry_id) }, generation)
        checkpoint.call(:outbox_written)
        outcome = WriteOutcome.success(written.status, written.payload.call(rows))
        store_receipt(command, outcome)
        checkpoint.call(:receipt_written)
        outcome
      end

      # Only writers with the same company, actor, operation and key wait on
      # each other.
      def lock_receipt_key(command)
        WriteSteps.lock_key(command.company_id, EntryCommand::ACTOR_TYPE, command.actor_id, command.operation, command.key)
      end

      def find_receipt(command)
        IdempotencyReceipt.find_by(company_id: command.company_id, actor_type: EntryCommand::ACTOR_TYPE,
                                   actor_id: command.actor_id, operation: command.operation, key: command.key)
      end

      def answer_from(receipt, command)
        return WriteOutcome.refusal(:idempotency_key_reused) unless receipt.fingerprint == command.fingerprint

        WriteOutcome.new(status: receipt.status, body: receipt.body)
      end

      # The one generation Timekeeping admits, read FOR SHARE so a fence waits
      # for this write to commit. nil while fenced or when the row is missing;
      # the write never creates the row, so nil refuses it.
      def locked_generation
        Admission.locked_generation
      end

      # The project a body names must be one the facts hold for this company;
      # one listed in missing_project_ids, or absent, is answered as not found.
      def project_known?(command)
        command.project_id.nil? || command.facts.projects.any? { |project| project.id == command.project_id }
      end

      def create_entry(command)
        checkpoint.call(:rows_locked)
        user_id = target_user_id(command)
        return user_id if user_id.is_a?(WriteOutcome)
        return WriteOutcome.refusal(:not_found) unless agent_owned?(command, command.body["agent_id"], user_id)

        entry = Entry.create!(command.entry_fields.merge(
          "company_id" => command.company_id, "user_id" => user_id, "bill_status" => command.bill_status_default
        ))
        Written.new(status: 201, changes: [Change.new(entry_id: entry.id, before: nil)],
                    payload: ->(rows) { EntryPresenter.call(rows.fetch(entry.id)) })
      end

      def update_entry(command)
        entry = locked_entries(command, [command.entry_id]).first
        checkpoint.call(:rows_locked)
        return WriteOutcome.refusal(:not_found) unless entry
        return WriteOutcome.refusal(:version_conflict) unless version_matches?(command, entry)

        refusal = change_refusal(command, entry, action: :update, bill_status: command.body["bill_status"])
        return refusal if refusal

        fields = command.entry_fields
        if command.body.key?("user_id")
          user_id = target_user_id(command)
          return user_id if user_id.is_a?(WriteOutcome)

          fields["user_id"] = user_id
        end
        committed = stored_values(entry).merge(fields)
        return WriteOutcome.refusal(:not_found) unless agent_owned?(command, committed["agent_id"], committed["user_id"])

        single_change(entry, fields)
      end

      def destroy_entry(command)
        entry = locked_entries(command, [command.entry_id]).first
        checkpoint.call(:rows_locked)
        return WriteOutcome.refusal(:not_found) unless entry
        return WriteOutcome.refusal(:version_conflict) unless version_matches?(command, entry)

        refusal = change_refusal(command, entry, action: :delete, bill_status: nil)
        return refusal if refusal

        single_change(entry, "discarded_at" => Time.current)
      end

      # Targets are only the entries the caller may see; any other id, from
      # another company, a colleague's entry for an employee, a discarded
      # entry or one that is not an id at all, is reported as not_found and
      # takes no part in the decision. A skipped entry is reported the same way.
      def bulk_change(command)
        requested = command.body.fetch("entry_ids")
        entries = locked_entries(command, requested.filter_map { |id| entry_id(id) }.uniq, visible_only: true)
        checkpoint.call(:rows_locked)
        decision = EntryDecision.bulk(action: BULK_ACTIONS.fetch(command.route), role: command.role,
                                      primary_role: command.primary_role, acting_user_id: command.actor_id,
                                      entries: entries.map { |entry| rule_facts(entry) },
                                      edit_days: command.facts.edit_days, today: command.today)
        return WriteOutcome.refusal(:forbidden) if decision == :forbidden

        fields = command.route == :bulk_move ? { "project_id" => command.project_id } : { "discarded_at" => Time.current }
        applied = entries.select { |entry| decision.fetch(entry.id) == :apply }
        changes = applied.map { |entry| apply_change(entry, fields) }
        Written.new(status: 200, changes:, payload: ->(_rows) { bulk_results(command, applied.map(&:id)) })
      end

      def bulk_results(command, applied_ids)
        result = BULK_RESULTS.fetch(command.route)
        results = command.body.fetch("entry_ids").map do |id|
          { "entry_id" => id, "result" => applied_ids.include?(entry_id(id)) ? result : NOT_FOUND_RESULT }
        end
        { "results" => results }
      end

      def entry_id(value)
        return value if value.is_a?(Integer) && value.positive?

        Integer(value, 10) if value.is_a?(String) && EntryCommand::ID.match?(value)
      end

      def single_change(entry, fields)
        change = apply_change(entry, fields)
        Written.new(status: 200, changes: [change], payload: ->(rows) { EntryPresenter.call(rows.fetch(entry.id)) })
      end

      def apply_change(entry, fields)
        before = stored_values(entry)
        entry.update!(fields.merge("version" => entry.version + 1))
        Change.new(entry_id: entry.id, before:)
      end

      def locked_entries(command, ids, visible_only: false)
        relation = Entry.where(company_id: command.company_id, id: ids, discarded_at: nil)
        if visible_only
          scope = TimekeepingRules::EntryRules.visible_scope(role: command.role, acting_user_id: command.actor_id)
          relation = relation.where(user_id: scope) unless scope == :company
        end
        # The reservation flag is read in a second statement once the locks
        # are held: a statement that waited on a lock still evaluates its
        # reservation subquery against the snapshot taken before the wait, so
        # it would miss a reservation the lock holder just committed.
        ids = relation.order(:id).lock("FOR UPDATE").pluck(:id)
        WriteSteps.reserved_rows(command.company_id, ids).values_at(*ids)
      end

      def version_matches?(command, entry)
        EntryDecision.version(if_match: command.if_match, current_version: entry.version) == :ok
      end

      def change_refusal(command, entry, action:, bill_status:)
        decision = EntryDecision.change(action:, bill_status:, role: command.role, primary_role: command.primary_role,
                                        acting_user_id: command.actor_id, entry: rule_facts(entry),
                                        edit_days: command.facts.edit_days,
                                        today: command.today)
        WriteOutcome.refusal(decision) unless decision == :ok
      end

      def rule_facts(entry)
        { id: entry.id, user_id: entry.user_id, work_date: entry.work_date, bill_status: entry.bill_status,
          locked: entry.reserved }
      end

      # The body's user_id resolved against the company's users from the
      # reference facts: the acting user when it is missing or names them.
      def target_user_id(command)
        requested = command.body["user_id"]
        decision = EntryDecision.target_user(acting_user_id: command.actor_id, role: command.role,
                                             requested_user_id: requested, company_user_ids: command.facts.user_ids)
        case decision
        when :acting then command.actor_id
        when :requested then Integer(requested.to_s, 10)
        else WriteOutcome.refusal(decision)
        end
      end

      # S7: the agent and user the write commits must be an agent of this
      # company and its own user, or the monolith projection refuses the
      # snapshot and every later delivery waits behind it. Checked on the
      # committed pair, so an update that changes only user_id under a stored
      # agent is refused too. An unknown agent, another company's agent and a
      # colleague's agent all answer not_found, so the answer reveals nothing
      # about other companies. The facts are read before the transaction, so
      # the projection's own agent checks stay as the backstop.
      def agent_owned?(command, agent_id, user_id)
        EntryDecision.agent_owner(agent_id:, user_id:, company_agents: command.facts.agent_owners) == :ok
      end

      def stored_values(entry)
        entry.attributes.except("reserved")
      end

      def write_audit(command, changes, rows)
        events = changes.map do |change|
          row = rows.fetch(change.entry_id)
          { entry_id: change.entry_id, before: change.before, after: stored_values(row), entry_created_at: row.created_at }
        end
        WriteSteps.write_audit(company_id: command.company_id, action: command.route.to_s, events:,
                               actor: { actor_type: EntryCommand::ACTOR_TYPE, actor_id: command.actor_id })
      end

      def store_receipt(command, outcome)
        IdempotencyReceipt.create!(
          company_id: command.company_id, actor_type: EntryCommand::ACTOR_TYPE, actor_id: command.actor_id,
          operation: command.operation, key: command.key, fingerprint: command.fingerprint,
          status: outcome.status, body: outcome.body, created_at: Time.current
        )
      end
  end
end
