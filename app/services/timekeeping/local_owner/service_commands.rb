# frozen_string_literal: true

require "digest"

module Timekeeping
  class LocalOwner
    # Carries out one mark-billed or detach-entries command on the prepared
    # monolith's own tables, in one savepoint, so the entry changes, their
    # audit rows, their outbox snapshots and the receipt commit together or not
    # at all. It mirrors Timekeeping::ServiceCommands in the Timekeeping
    # service, with one difference in order, in these steps:
    #
    # 1. Lock the receipt key (company, service, operation, operation_id), then
    #    the command's target: the invoice, under the same key a reservation
    #    commit takes, so a commit and a mark-billed of one invoice wait in turn.
    # 2. Read the admitted generation FOR SHARE. A generation that is not that
    #    generation is stale_generation. This comes before the receipt, so a
    #    retry at an old generation is refused even when its earlier answer is
    #    stored; the service replays first.
    # 3. Re-read the receipt: a stored answer is replayed.
    # 4. Lock the target entries FOR UPDATE in id order, then select them again
    #    under those locks.
    # 5. Write each entry with version + 1, one audit row holding the changed
    #    field before and after, and under the outbox lock one snapshot.
    # 6. Store the receipt.
    #
    # checkpoint is called with each step's name from STEPS as it finishes, so
    # a spec can fail the write at a known point; an error it raises is never
    # rescued here.
    class ServiceCommands
      UUID = ReservationOperations::UUID

      # What each command changes. lock names the target's advisory lock;
      # targets selects the company's entries the command changes; changes is
      # the field it writes on each; count is the answer's key; target is the
      # params key naming the target id.
      COMMANDS = {
        mark_billed: {
          target: "invoice_id",
          lock: ReservationOperations::INVOICE_LOCK,
          # Kept, unbilled entries with a committed reservation for the invoice.
          targets: lambda do |company_id, invoice_id|
            committed = ReservationOperations::Reservation
              .where(company_id:, invoice_id:, state: ReservationOperations::COMMITTED)
            LocalEntry.where(company_id:, discarded_at: nil, id: committed.select(:entry_id))
              .where.not(bill_status: TimekeepingRules::EntryRules::BILLED)
          end,
          changes: { "bill_status" => TimekeepingRules::EntryRules::BILLED }.freeze,
          count: "billed"
        }.freeze,
        detach_entries: {
          target: "agent_id",
          lock: "agent",
          # Every entry of the company that names the agent, discarded ones
          # included, so none keeps a reference to it.
          targets: ->(company_id, agent_id) { LocalEntry.where(company_id:, agent_id:) },
          changes: { "agent_id" => nil }.freeze,
          count: "detached"
        }.freeze
      }.freeze

      # :reek:LongParameterList
      def self.call(route:, company_id:, generation:, actor:, params:, checkpoint:)
        new(route:, company_id:, generation:, actor:, params:, checkpoint:).call
      end

      # :reek:LongParameterList
      def initialize(route:, company_id:, generation:, actor:, params:, checkpoint:)
        @route = route.to_sym
        @command = COMMANDS.fetch(@route)
        @company_id = company_id
        @generation = generation
        @actor = actor
        @params = params
        @body = params.fetch("body", nil) || {}
        @checkpoint = checkpoint
      end

      def call
        # A path id that cannot name a row is answered as not found, as a
        # missing one is and as the service answers it.
        return Outcome.refusal(:not_found) if target_id.nil?
        return Outcome.refusal(:invalid_request) unless valid_request?

        attempt
      rescue ReceiptTaken
        # A backstop: the receipt-key lock normally stops two writers with one
        # key from both reaching the insert. The failed attempt has rolled back
        # every row it wrote, so the steps run again, check the generation
        # first and then replay the receipt that now exists.
        attempt
      end

      private

        attr_reader :route, :command, :company_id, :generation, :actor, :params, :body, :checkpoint

        # Each attempt runs in its own savepoint, so a failure rolls back this
        # write even when the caller has a transaction open and rescues it.
        def attempt
          ApplicationRecord.transaction(requires_new: true) { run }
        end

        def run
          WriteSteps.lock_key(company_id, ReservationOperations::ACTOR_TYPE, actor.name, operation, operation_id)
          WriteSteps.lock_key(company_id, command.fetch(:lock), target_id)
          checkpoint.call(:operation_key_locked)
          stored_generation = WriteSteps.admitted_generation
          return Outcome.refusal(:stale_generation) unless WriteSteps.generation_matches?(generation, stored_generation)

          checkpoint.call(:generation_checked)
          receipt = find_receipt
          checkpoint.call(:receipt_checked)
          return replay(receipt) if receipt

          entries = locked_targets
          checkpoint.call(:rows_locked)
          change_entries(entries, stored_generation)
          finish(command.fetch(:count) => entries.size)
        end

        # Request values

        def operation_id
          body["operation_id"]
        end

        # The target id from the path, as an Integer; nil when it is not one a
        # bigint column can hold.
        def target_id
          value = params[command.fetch(:target)]
          value = Integer(value, 10) if value.is_a?(String) && ID.match?(value)
          value if WriteSteps.id?(value)
        end

        def valid_request?
          body.is_a?(Hash) && UUID.match?(operation_id.to_s)
        end

        # The target is part of the receipt's operation, so one operation id
        # used for two invoices or two agents is two commands, not a reuse.
        def operation
          "#{route} #{target_id}"
        end

        # Entries

        # Locks the targets in id order, then selects them again once the locks
        # are held. A statement that waited on a lock still reads reservations
        # as they were before the wait, so without the second read a
        # mark-billed could bill an entry a successor invoice took meanwhile.
        def locked_targets
          targets = command.fetch(:targets).call(company_id, target_id)
          ids = targets.order(:id).lock("FOR UPDATE").pluck(:id)
          entries = targets.where(id: ids).order(:id).to_a
          checkpoint.call(:decision_made)
          entries
        end

        def change_entries(entries, stored_generation)
          return if entries.empty?

          changes = command.fetch(:changes)
          ids = entries.map(&:id)
          LocalEntry.where(company_id:, id: ids)
            .update_all(changes.merge("version" => Arel.sql("version + 1"), "updated_at" => Time.current))
          rows = WriteSteps.reserved_rows(company_id, ids)
          checkpoint.call(:entry_written)
          write_audit(entries, changes)
          checkpoint.call(:audit_written)
          WriteSteps.write_outbox(company_id:, rows: ids.map { |id| rows.fetch(id) }, generation: stored_generation)
          checkpoint.call(:outbox_written)
        end

        def write_audit(entries, changes)
          now = Time.current
          entries.each do |entry|
            AuditRow.create!(
              company_id:, entry_id: entry.id, action: route.to_s, actor_type: ReservationOperations::ACTOR_TYPE,
              actor_id: nil, actor_name: actor.name, before: entry.attributes.slice(*changes.keys), after: changes,
              entry_created_at: entry.created_at, created_at: now
            )
          end
        end

        # Receipts

        def find_receipt
          ServiceReceipt.find_by(company_id:, actor_name: actor.name, operation:, key: operation_id)
        end

        # The body carries nothing a replay must repeat beyond the generation,
        # which plays no part once the command has run, so every receipt found
        # under the key is a replay of this command.
        def replay(receipt)
          Outcome.new(status: receipt.status, body: WriteSteps.replayed_body(receipt.body))
        end

        def finish(payload)
          outcome = Outcome.success(200, payload)
          store_receipt(outcome)
          checkpoint.call(:receipt_written)
          outcome
        end

        # Only the receipt insert's uniqueness error is tagged, so one raised
        # from a checkpoint is never retried as a receipt another writer stored.
        def store_receipt(outcome)
          ServiceReceipt.create!(
            company_id:, actor_name: actor.name, operation:, key: operation_id, fingerprint:,
            status: outcome.status, body: WriteSteps.receipt_body(outcome.body), created_at: Time.current
          )
        rescue ActiveRecord::RecordNotUnique => error
          raise ReceiptTaken, error.message
        end

        # The receipt table requires a fingerprint; the command's route and
        # target are all a replay must repeat, and the key already names them.
        def fingerprint
          Digest::SHA256.hexdigest(operation)
        end
    end
  end
end
