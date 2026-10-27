# frozen_string_literal: true

require "digest"

module Timekeeping
  # Carries out one mark-billed or detach-entries command in a single
  # transaction, so the entry changes, their audit rows, their outbox
  # snapshots and the receipt commit together or not at all. Any refusal or
  # failure leaves nothing, so a retry runs as a first attempt. The steps, in
  # order:
  #
  # 1. Lock the receipt key (company, service, operation, operation_id), then
  #    the command's target: the invoice, under the same key a reservation
  #    commit takes, so a commit and a mark-billed of one invoice wait in turn.
  # 2. Re-read the receipt: a stored answer is replayed. It comes before the
  #    generation check, so a retry of finished work replays even after the
  #    generation has moved.
  # 3. Read the admitted generation (Timekeeping::Admission) FOR SHARE; a
  #    body generation that is not that generation, or any generation while
  #    fenced, is stale_generation.
  # 4. Lock the target entries FOR UPDATE in id order, then select them again
  #    under those locks.
  # 5. Write each entry with version + 1, one audit row holding the changed
  #    field before and after, and under the outbox lock one snapshot.
  # 6. Store the receipt.
  #
  # checkpoint is called with the name of each step as it finishes, so a spec
  # can hold a transaction at a known point or fail it after a given write.
  class ServiceCommands
    # One command, its values already checked by the caller: company_id and
    # target_id are Integers, operation_id is a UUID string and actor_name is
    # the verified service name. target_id is the invoice for :mark_billed
    # and the agent for :detach_entries; generation is the body's value as
    # sent.
    Request = Data.define(:route, :company_id, :actor_name, :target_id, :operation_id, :generation)

    # What each command changes. lock names the target's advisory lock;
    # targets selects the company's entries the command changes; changes is
    # the field it writes on each; count is the answer's key.
    COMMANDS = {
      mark_billed: {
        lock: ReservationOperations::INVOICE_LOCK,
        # Kept, unbilled entries with a committed reservation for the invoice.
        targets: lambda do |company_id, invoice_id|
          committed = Reservation.where(company_id:, invoice_id:, state: ReservationOperations::COMMITTED)
          Entry.where(company_id:, discarded_at: nil, id: committed.select(:entry_id))
            .where.not(bill_status: TimekeepingRules::EntryRules::BILLED)
        end,
        changes: { "bill_status" => TimekeepingRules::EntryRules::BILLED }.freeze,
        count: "billed"
      }.freeze,
      detach_entries: {
        lock: "agent",
        # Every entry of the company that names the agent, discarded ones
        # included, so none keeps a reference to it.
        targets: ->(company_id, agent_id) { Entry.where(company_id:, agent_id:) },
        changes: { "agent_id" => nil }.freeze,
        count: "detached"
      }.freeze
    }.freeze

    def initialize(checkpoint: ->(_step) { })
      @checkpoint = checkpoint
    end

    # Takes the lock a detach-entries command of this agent takes, so an entry
    # write naming the agent and the detach run one after the other.
    def self.lock_agent(company_id, agent_id)
      WriteSteps.lock_key(company_id, COMMANDS.fetch(:detach_entries).fetch(:lock), agent_id)
    end

    # The highest service receipt id allocated so far, read before an entry
    # write fetches its reference facts. A receipt id is taken when the
    # command inserts it, so a later detach always gets a higher id. Ids are
    # never reused and are allocated outside any transaction.
    def self.detach_fence
      ApplicationRecord.connection.select_value(
        "SELECT COALESCE(pg_sequence_last_value('service_idempotency_receipts_id_seq'::regclass), 0)"
      ).to_i
    end

    # Whether a detach-entries command of this agent committed after the
    # write's fence was read, so the write's facts may still list an agent the
    # monolith has since deleted. The monolith leaves an agent out of its
    # facts while it is being deleted, so facts that list the agent were read
    # either before the deletion began, and so before any such detach, or
    # after a deletion rolled back. An older detach is therefore one whose
    # deletion failed, and it does not refuse writes for the agent that
    # survived it.
    def self.agent_detached?(company_id, agent_id, after:)
      ServiceIdempotencyReceipt.where(company_id:, operation: operation_name(:detach_entries, agent_id))
        .where("id > ?", after).exists?
    end

    # The target is part of the receipt's operation, so one operation id
    # used for two invoices or two agents is two commands, not a reuse.
    def self.operation_name(route, target_id)
      "#{route} #{target_id}"
    end

    def call(request)
      ApplicationRecord.transaction { run(request) }
    rescue ActiveRecord::RecordNotUnique
      # A backstop: the receipt-key lock normally stops two writers with one
      # key from both reaching the insert. The failed transaction has rolled
      # back every row it wrote, so the stored receipt decides the answer.
      receipt = find_receipt(request)
      raise unless receipt

      replay(receipt)
    rescue WriteSteps::UnpublishableRows => error
      # A stored row the projection would refuse. The transaction has rolled
      # back the entry changes, their audit rows and the receipt, so a retry
      # is checked again against what is stored then.
      error.outcome
    end

    private

      attr_reader :checkpoint

      def run(request)
        command = COMMANDS.fetch(request.route)
        WriteSteps.lock_key(request.company_id, ReservationOperations::ACTOR_TYPE, request.actor_name,
                            operation(request), request.operation_id)
        WriteSteps.lock_key(request.company_id, command.fetch(:lock), request.target_id)
        receipt = find_receipt(request)
        checkpoint.call(:receipt_checked)
        return replay(receipt) if receipt

        generation = Admission.locked_generation
        checkpoint.call(:generation_checked)
        return WriteOutcome.refusal(:stale_generation) unless WriteSteps.generation_matches?(request.generation, generation)

        entries = locked_targets(command.fetch(:targets).call(request.company_id, request.target_id))
        checkpoint.call(:rows_locked)
        change_entries(request, command.fetch(:changes), entries, generation)
        finish(request, command.fetch(:count) => entries.size)
      end

      # Locks the targets in id order, then selects them again once the locks
      # are held. A statement that waited on a lock still reads the
      # reservations as they were before the wait, so without the second
      # read a mark-billed could bill an entry whose committed reservation a
      # successor invoice took over while it waited.
      def locked_targets(targets)
        ids = targets.order(:id).lock.pluck(:id)
        targets.where(id: ids).order(:id).to_a
      end

      def change_entries(request, changes, entries, generation)
        return if entries.empty?

        ids = entries.map(&:id)
        Entry.where(company_id: request.company_id, id: ids)
          .update_all(changes.merge("version" => Arel.sql("version + 1"), "updated_at" => Time.current))
        rows = WriteSteps.reserved_rows(request.company_id, ids)
        checkpoint.call(:entry_written)
        events = entries.map do |entry|
          { entry_id: entry.id, before: entry.attributes.slice(*changes.keys), after: changes,
            entry_created_at: entry.created_at }
        end
        WriteSteps.write_audit(company_id: request.company_id, action: request.route.to_s, events:,
                               actor: { actor_type: ReservationOperations::ACTOR_TYPE, actor_name: request.actor_name })
        checkpoint.call(:audit_written)
        WriteSteps.write_outbox(ids.map { |id| rows.fetch(id) }, generation)
        checkpoint.call(:outbox_written)
      end

      def finish(request, payload)
        outcome = WriteOutcome.success(200, payload)
        ServiceIdempotencyReceipt.create!(
          company_id: request.company_id, actor_name: request.actor_name, operation: operation(request),
          key: request.operation_id, fingerprint: fingerprint(request), status: outcome.status, body: outcome.body,
          created_at: Time.current
        )
        checkpoint.call(:receipt_written)
        outcome
      end

      def operation(request)
        self.class.operation_name(request.route, request.target_id)
      end

      def find_receipt(request)
        ServiceIdempotencyReceipt.find_by(company_id: request.company_id, actor_name: request.actor_name,
                                          operation: operation(request), key: request.operation_id)
      end

      # The body carries nothing a replay must repeat beyond the generation,
      # which plays no part once the command has run, so every receipt found
      # under the key is a replay of this command.
      def replay(receipt)
        WriteOutcome.new(status: receipt.status, body: receipt.body)
      end

      # The receipt table requires a fingerprint; the command's route and
      # target are all a replay must repeat, and the key already names them.
      def fingerprint(request)
        Digest::SHA256.hexdigest(operation(request))
      end
  end
end
