# frozen_string_literal: true

require "digest"

module Timekeeping
  class LocalOwner
    # The prepared monolith's mark-billed and detach-entries commands, for
    # background services, against the monolith's own entries, entry_audits,
    # entry_outbox_items and idempotency_records tables. It mirrors the
    # Timekeeping service's Timekeeping::ServiceCommands, with the step order
    # of ReservationOperations.
    #
    # ServiceAccess decides first, before any lock or read, so a refused
    # caller never sees a stored answer. Then everything runs in one
    # savepoint, in this order:
    #
    # 1. Lock the operation key (company, service name, operation_id), the
    #    key ReservationOperations takes, so one key used for two targets
    #    waits in turn and the second sees the first one's receipt. Then lock
    #    the full key (company, service name, "<route> <target>",
    #    operation_id), then the target: the invoice with
    #    Invoices::OperationLock, or (company, "agent", agent_id).
    # 2. Read the ownership generation FOR SHARE NOWAIT. A body generation
    #    that is not the admitted one is stale_generation. The service
    #    replays before this check; this order is deliberately the reverse,
    #    so a retry at an old generation is refused even when its earlier
    #    answer is stored.
    # 3. Replay the receipt stored under the key for this route. One stored
    #    for another target answers idempotency_key_reused: unlike the
    #    service, which runs it as a second command.
    # 4. Lock the target entries FOR UPDATE in id order, then select them
    #    again under those locks.
    # 5. Write each with version + 1, then, unless a stored row is one the
    #    projection would refuse, one audit row holding the changed field
    #    before and after and one outbox snapshot.
    # 6. Store the receipt when an entry changed, or when the command is one
    #    that stores it for a target the company owns and the company owns
    #    the target (contracts/timekeeping/idempotency.yml
    #    owned_target_stored_operations). A command that stored nothing is
    #    evaluated again on a retry.
    #
    # A refusal decided before step 5 writes nothing. An unpublishable row
    # raises inside the savepoint and is answered after the rollback.
    # checkpoint is called with names from LocalOwner::STEPS as each step
    # finishes.
    class ServiceCommands
      ACTOR_TYPE = ReservationOperations::ACTOR_TYPE
      ROW_LOCK = ReservationOperations::ROW_LOCK
      UUID = ReservationOperations::UUID
      AGENT_LOCK = "agent"

      # What each command changes. target_param names the params key holding
      # its target; lock takes the target's lock; targets selects the
      # company's entries the command changes; changes is the field it
      # writes on each; count is the answer's key; owned_target, when present,
      # answers whether the company owns the target, and a run that changed no
      # entry stores its receipt only when it does.
      COMMANDS = {
        mark_billed: {
          target_param: "invoice_id",
          lock: lambda do |company_id, invoice_id|
            Invoices::OperationLock.acquire!(ApplicationRecord.connection, company_id:, invoice_id:)
          end,
          # Kept, unbilled entries with a committed reservation for the
          # invoice. Invoice numbers repeat across companies, so the
          # reservation is matched by company too.
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
          target_param: "agent_id",
          lock: ->(company_id, agent_id) { ServiceCommands.lock_agent(company_id, agent_id) },
          # Every entry of the company that names the agent, discarded ones
          # included, so none keeps a reference to it.
          targets: ->(company_id, agent_id) { LocalEntry.where(company_id:, agent_id:) },
          changes: { "agent_id" => nil }.freeze,
          count: "detached",
          # The receipt is the detach marker agent_detached? reads, so a detach
          # of the company's own agent stores it even when it detached nothing.
          # One naming another company's agent, or no agent, stores nothing.
          # A plain read, with no row lock, so it neither waits on the lock
          # the agent's destroy holds nor skips the agent being deleted.
          owned_target: ->(company_id, agent_id) { Agent.where(company_id:, id: agent_id).exists? }
        }.freeze
      }.freeze

      # One request, its values checked: target_id is a positive Integer and
      # operation_id a UUID string.
      Request = Data.define(:route, :actor_name, :target_id, :operation_id) do
        def operation_name
          ServiceCommands.operation_name(route, target_id)
        end

        def fingerprint
          Digest::SHA256.hexdigest(operation_name)
        end
      end
      private_constant :Request

      # Takes the lock a detach-entries command of this agent takes, so an
      # entry write naming the agent and the detach run one after the other.
      def self.lock_agent(company_id, agent_id)
        WriteSteps.lock_key(company_id, AGENT_LOCK, agent_id)
      end

      # The target is part of the receipt's operation, as in the service. Here
      # an operation id reused for another target is refused as
      # idempotency_key_reused (see find_receipt).
      def self.operation_name(route, target_id)
        "#{route} #{target_id}"
      end

      # The id of the newest committed detach-entries receipt of this agent
      # in the company, or 0 when there is none. An entry write reads it
      # before it takes the agent lock: a detach still in flight then holds
      # that lock, and its receipt, once committed, has a higher id.
      def self.detach_marker(company_id, agent_id)
        detach_receipts(company_id, agent_id).maximum(:id) || 0
      end

      # Whether a detach-entries command of this agent in the company stored
      # its receipt after the marker the write read. An older detach does not
      # refuse writes for an agent that still exists. Every detach of one of
      # the company's own agents stores its receipt, a zero-entry one included
      # (COMMANDS owned_target), so this marker is never missing for an agent
      # being deleted.
      def self.agent_detached?(company_id, agent_id, after:)
        detach_receipts(company_id, agent_id).where("id > ?", after).exists?
      end

      def self.detach_receipts(company_id, agent_id)
        Receipt.where(company_id:, actor_type: ACTOR_TYPE, operation: operation_name(:detach_entries, agent_id))
      end
      private_class_method :detach_receipts

      # :reek:LongParameterList
      def initialize(operation:, company_id:, generation:, actor:, params:, checkpoint:)
        @route = operation.to_sym
        raise ArgumentError, "unknown operation #{operation.inspect}" unless COMMANDS.key?(@route)

        @company_id = company_id
        @generation = generation
        @actor = actor
        @params = params
        @checkpoint = checkpoint
      end

      def call
        access = ServiceAccess.call(actor:, operation: route, company_id:)
        return Outcome.refusal(access) unless access == :ok

        @request = build_request
        return Outcome.refusal(:invalid_request) unless request

        attempt
      rescue ReceiptTaken
        # A backstop: the operation locks normally stop two writers with one
        # key from both reaching the insert. The failed attempt has rolled
        # back every row it wrote. Running the steps again checks the
        # generation first and then replays what is stored now.
        attempt
      end

      private

        attr_reader :route, :company_id, :generation, :actor, :params, :checkpoint, :request

        def command
          COMMANDS.fetch(route)
        end

        # Each attempt runs in its own savepoint, so a refusal raised after a
        # write, or a NOWAIT read that found the row locked, rolls back every
        # row the attempt wrote and leaves the caller's transaction usable.
        def attempt
          ApplicationRecord.transaction(requires_new: true) { write }
        rescue WriteSteps::OwnershipQueued
          Outcome.refusal(:stale_generation)
        rescue WriteSteps::UnpublishableRows => error
          error.outcome
        end

        def write
          lock_operation_keys
          checkpoint.call(:operation_key_locked)
          command.fetch(:lock).call(company_id, request.target_id)
          stored_generation = WriteSteps.locked_generation_nowait
          return Outcome.refusal(:stale_generation) unless WriteSteps.generation_matches?(generation, stored_generation)

          checkpoint.call(:generation_checked)
          receipt = find_receipt
          checkpoint.call(:receipt_checked)
          return receipt_answer(receipt) if receipt

          entries = locked_targets
          checkpoint.call(:rows_locked)
          change_entries(entries, stored_generation)
          finish(entries)
        end

        # Answers with the count of changed entries. The receipt is stored only
        # when an entry changed, or when the company owns the command's target
        # and the command stores its receipt for an owned target.
        def finish(entries)
          outcome = Outcome.success(200, command.fetch(:count) => entries.size)
          if entries.any? || owned_target?
            store_receipt(outcome)
            checkpoint.call(:receipt_written)
          end
          outcome
        end

        # A command without owned_target never stores a receipt for a run that
        # changed nothing.
        def owned_target?
          owned_target = command[:owned_target]
          owned_target.present? && owned_target.call(company_id, request.target_id)
        end

        # Only the params keys below are read, so a company_id or actor field
        # elsewhere in params changes nothing. A missing target is refused
        # here, so a detach can never match the entries with no agent.
        def build_request
          target_id = WriteSteps.id_value(params[command.fetch(:target_param)])
          operation_id = params["operation_id"]
          return unless target_id && operation_id.is_a?(String) && UUID.match?(operation_id)

          Request.new(route:, actor_name: actor.name, target_id:, operation_id:)
        end

        # The first key is the one ReservationOperations takes, without the
        # target: the full key alone would let one operation_id sent for two
        # targets run at once, and neither would see the other's receipt.
        def lock_operation_keys
          WriteSteps.lock_key(company_id, ACTOR_TYPE, request.actor_name, request.operation_id)
          WriteSteps.lock_key(company_id, ACTOR_TYPE, request.actor_name, request.operation_name, request.operation_id)
        end

        # Locks the targets in id order, then selects them again once the
        # locks are held. A statement that waited on a lock still reads the
        # reservations as they were before the wait, so without the second
        # read a mark-billed could bill an entry whose committed reservation
        # was released while it waited.
        def locked_targets
          targets = command.fetch(:targets).call(company_id, request.target_id)
          ids = targets.order(:id).lock(ROW_LOCK).pluck(:id)
          targets.where(id: ids).order(:id).to_a
        end

        def change_entries(entries, stored_generation)
          return if entries.empty?

          changes = command.fetch(:changes)
          ids = entries.map(&:id)
          LocalEntry.where(company_id:, id: ids)
            .update_all(changes.merge("version" => Arel.sql("version + 1"), "updated_at" => Time.current))
          rows = WriteSteps.reserved_rows(company_id, ids).values_at(*ids)
          checkpoint.call(:entry_written)
          invalid = EntryOutbox.invalid_fields(rows)
          raise WriteSteps::UnpublishableRows, invalid if invalid.any?

          WriteSteps.write_audit(company_id:, action: route.to_s, events: audit_events(entries, changes),
                                 actor: { actor_type: ACTOR_TYPE, actor_name: request.actor_name })
          checkpoint.call(:audit_written)
          WriteSteps.write_outbox(rows, stored_generation)
          checkpoint.call(:outbox_written)
        end

        def audit_events(entries, changes)
          entries.map do |entry|
            { entry_id: entry.id, before: entry.attributes.slice(*changes.keys), after: changes,
              entry_created_at: entry.created_at }
          end
        end

        # Receipts

        # Service receipts carry the service name and no actor_id.
        def store_receipt(outcome)
          Receipt.create!(
            company_id:, actor_type: ACTOR_TYPE, actor_id: nil, actor_name: request.actor_name,
            operation: request.operation_name, key: request.operation_id, fingerprint: request.fingerprint,
            status: outcome.status, body: JSON.generate(outcome.body), created_at: Time.current
          )
        rescue ActiveRecord::RecordNotUnique => error
          raise ReceiptTaken, error.message
        end

        # The receipt stored under this key for this route, whatever its
        # target, so a key reused for another target is found and refused.
        def find_receipt
          Receipt.where(company_id:, actor_type: ACTOR_TYPE, actor_name: request.actor_name, key: request.operation_id)
            .where("operation LIKE ?", "#{Receipt.sanitize_sql_like(route.to_s)} %")
            .first
        end

        def receipt_answer(receipt)
          return Outcome.refusal(:idempotency_key_reused) unless receipt.fingerprint == request.fingerprint

          Outcome.new(status: receipt.status, body: JSON.parse(receipt.body))
        end
    end
  end
end
