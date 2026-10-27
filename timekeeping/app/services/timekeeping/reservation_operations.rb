# frozen_string_literal: true

require "digest"

module Timekeeping
  # Carries out one prepare, commit or abort of an invoice's reservations in a
  # single transaction, so the reservation change, the locked flips it causes
  # (entry version, audit and outbox rows), the operation row and the receipt
  # commit together or not at all. Any refusal or failure leaves nothing, so a
  # retry runs as a first attempt. The steps, in order:
  #
  # 1. Lock the operation key (company, service, operation_id), then the
  #    company's invoice, so commit and abort of one operation, and prepares
  #    for one invoice, wait in turn.
  # 2. Re-read the stored answer: the operation row for prepare, the receipt
  #    for commit and abort. It comes before the generation check, so a retry
  #    of finished work replays even after the generation has moved.
  # 3. Read the admitted generation (Timekeeping::Admission) FOR SHARE; a
  #    body generation that is not that generation, or any generation while
  #    fenced, is stale_generation.
  # 4. Lock the entries involved FOR UPDATE in id order, then read their
  #    reservations and decide with TimekeepingRules::ReservationDecision.
  # 5. Change the reservations. Each entry whose locked flag flips gets
  #    version + 1, one audit row and, under the outbox lock, one snapshot.
  # 6. Store the operation state, and for commit and abort the receipt.
  #
  # checkpoint is called with the name of each step as it finishes, so a spec
  # can hold a transaction at a known point or fail it after a given write.
  class ReservationOperations
    # The reservation wire carries no invoice status, so the provider applies
    # the desired set prepare stored as a draft's. Keeping a non-draft
    # invoice's entries is the job of the boundary that builds that set; a
    # retained disposition still releases nothing here.
    WIRE_INVOICE_STATUS = TimekeepingRules::ReservationDecision::DRAFT_STATUS
    ACTOR_TYPE = "service"
    INVOICE_LOCK = "invoice"
    PROVISIONAL = TimekeepingRules::ReservationDecision::PROVISIONAL
    COMMITTED = TimekeepingRules::ReservationDecision::COMMITTED
    RETAINED = "retained"

    # Operation states. COMMITTED names both a committed operation and a
    # committed reservation, as the contract does.
    PREPARED = "prepared"
    ABORTED = "aborted"

    # One request, its values already checked by the caller: company_id and
    # invoice_id are Integers, operation_id is a UUID string, actor_name is
    # the verified service name, disposition is "active" or "retained" and
    # entry_ids are Integers (both used by prepare only), and generation is
    # the body's value as sent. route is :prepare, :commit or :abort.
    Request = Data.define(:route, :company_id, :actor_name, :invoice_id, :operation_id, :generation, :disposition,
                          :entry_ids)

    ROUTES = { prepare: :prepare, commit: :commit, abort: :abort_operation }.freeze

    # What commit and abort answer for an operation that is already terminal:
    # the first of them won, so this one changes nothing.
    TERMINAL_ANSWERS = {
      commit: { "reserved" => 0, "released" => 0 }.freeze,
      abort: { "dropped" => 0 }.freeze
    }.freeze

    def initialize(checkpoint: ->(_step) { })
      @checkpoint = checkpoint
    end

    def call(request)
      ApplicationRecord.transaction { run(request) }
    rescue ActiveRecord::RecordNotUnique
      # A backstop: the operation and invoice locks normally stop two writers
      # from both reaching an insert. The failed transaction has rolled back
      # every row it wrote, so what is stored now decides the answer.
      stored = stored_answer(request) || (request.route == :prepare && unresolved_refusal(request))
      raise unless stored

      stored
    rescue WriteSteps::UnpublishableRows => error
      # A flipped entry's stored row the projection would refuse. The
      # transaction has rolled back the reservation change, the operation row,
      # the flips and the receipt, so a retry is checked again against what is
      # stored then.
      error.outcome
    end

    private

      attr_reader :checkpoint

      def run(request)
        WriteSteps.lock_key(request.company_id, ACTOR_TYPE, request.actor_name, request.operation_id)
        WriteSteps.lock_key(request.company_id, INVOICE_LOCK, request.invoice_id)
        stored = stored_answer(request)
        checkpoint.call(:operation_checked)
        return stored if stored

        generation = Admission.locked_generation
        checkpoint.call(:generation_checked)
        return WriteOutcome.refusal(:stale_generation) unless WriteSteps.generation_matches?(request.generation, generation)

        send(ROUTES.fetch(request.route), request, generation)
      end

      # Prepare answers from its operation row with the operation's current
      # state; commit and abort answer from their receipt. nil when neither
      # is stored yet.
      def stored_answer(request)
        if request.route == :prepare
          operation = find_operation(request)
          operation && prepare_replay(operation, request)
        else
          receipt = find_receipt(request)
          receipt && receipt_answer(receipt, request)
        end
      end

      def prepare(request, generation)
        unresolved = unresolved_refusal(request)
        return unresolved if unresolved

        entries = lock_entries(request.company_id, request.entry_ids)
        checkpoint.call(:rows_locked)
        kept_ids = entries.filter_map { |entry| entry.id if entry.discarded_at.nil? }
        decision = TimekeepingRules::ReservationDecision.call(
          current: decision_reservations(request.company_id, kept_ids, request.invoice_id), desired: request.entry_ids,
          disposition: request.disposition, invoice_status: WIRE_INVOICE_STATUS
        )
        return conflict_refusal(decision[:conflicts]) unless decision[:conflicts].empty?

        operation = InvoiceOperation.create!(
          company_id: request.company_id, invoice_id: request.invoice_id, operation_id: request.operation_id,
          actor_name: request.actor_name, state: PREPARED, desired_entry_ids: request.entry_ids,
          disposition: request.disposition, generation:, created_at: Time.current
        )
        reserve_provisionally(operation, decision[:reserve] + retained_by_this(operation, request.entry_ids))
        record_locked_flips(request, entries, generation)
        prepare_answer(operation)
      end

      # The desired entries this invoice already holds only as a retained
      # owner. A successor's prepare may take such an entry, so this operation
      # claims each one with a provisional row as well: whichever operation
      # prepares first holds the entry, the other is refused as
      # provisional_elsewhere, and each commit then finds its whole desired
      # set reserved.
      def retained_by_this(operation, entry_ids)
        invoice_committed(operation).where(entry_id: entry_ids, disposition: RETAINED).pluck(:entry_id)
      end

      def commit(request, generation)
        operation = find_operation(request)
        return WriteOutcome.refusal(:not_found) unless operation&.invoice_id == request.invoice_id
        return finish(request, TERMINAL_ANSWERS.fetch(:commit)) unless operation.state == PREPARED

        entries = lock_entries(request.company_id, (own_provisional(operation) + invoice_committed(operation)).pluck(:entry_id))
        checkpoint.call(:rows_locked)
        claimed_ids = own_provisional(operation).pluck(:entry_id)
        held_ids = invoice_committed(operation).pluck(:entry_id)
        # A claimed entry this invoice already held is kept, not newly reserved.
        reserved_ids = claimed_ids - held_ids
        released_ids = TimekeepingRules::ReservationDecision.call(
          current: decision_reservations(request.company_id, held_ids, operation.invoice_id),
          desired: operation.desired_entry_ids, disposition: operation.disposition, invoice_status: WIRE_INVOICE_STATUS
        )[:release]

        make_desired_set_the_reservation_set(operation, claimed_ids, released_ids)
        record_locked_flips(request, entries, generation)
        operation.update!(state: COMMITTED, finished_at: Time.current)
        finish(request, "reserved" => reserved_ids.size, "released" => released_ids.size)
      end

      def abort_operation(request, generation)
        operation = find_operation(request)
        return WriteOutcome.refusal(:not_found) unless operation&.invoice_id == request.invoice_id
        return finish(request, TERMINAL_ANSWERS.fetch(:abort)) unless operation.state == PREPARED

        entries = lock_entries(request.company_id, own_provisional(operation).pluck(:entry_id))
        checkpoint.call(:rows_locked)
        # A claim on an entry this invoice still holds as its retained owner
        # gives nothing up, so it is not counted as dropped.
        kept = invoice_committed(operation).select(:entry_id)
        dropped = own_provisional(operation).where.not(entry_id: kept).delete_all
        own_provisional(operation).delete_all
        record_locked_flips(request, entries, generation)
        operation.update!(state: ABORTED, finished_at: Time.current)
        finish(request, "dropped" => dropped)
      end

      # Commit order matters for the one-committed-per-entry index: a retained
      # committed row on an entry this operation claimed gives way first (a
      # predecessor's, or this invoice's own when it claimed it back), then
      # the released rows go, then this operation's provisional rows become
      # committed, and every row the invoice holds takes the operation's
      # disposition. An active committed row is never removed: prepare refuses
      # such an entry to every other invoice.
      def make_desired_set_the_reservation_set(operation, claimed_ids, released_ids)
        Reservation.where(company_id: operation.company_id, entry_id: claimed_ids, state: COMMITTED,
                          disposition: RETAINED).delete_all
        invoice_committed(operation).where(entry_id: released_ids).delete_all
        own_provisional(operation).update_all(state: COMMITTED)
        invoice_committed(operation).update_all(disposition: operation.disposition)
      end

      def reserve_provisionally(operation, entry_ids)
        return if entry_ids.empty?

        now = Time.current
        Reservation.insert_all!(entry_ids.map do |entry_id|
          { company_id: operation.company_id, entry_id:, invoice_id: operation.invoice_id, state: PROVISIONAL,
            disposition: operation.disposition, operation_id: operation.operation_id,
            invoice_operation_id: operation.id, created_at: now }
        end)
      end

      # Rows are selected by the owning operation's id, never by operation_id
      # alone, so another service's operation with the same id is not touched.
      def own_provisional(operation)
        Reservation.where(company_id: operation.company_id, invoice_operation_id: operation.id, state: PROVISIONAL)
      end

      def invoice_committed(operation)
        Reservation.where(company_id: operation.company_id, invoice_id: operation.invoice_id, state: COMMITTED)
      end

      # The company's entries with these ids, discarded ones included, locked
      # in id order so two writers over the same entries wait in turn. The
      # reservation flag is read in a second statement once the locks are
      # held: a statement that waited on a lock still evaluates its
      # reservation subquery against the snapshot taken before the wait, so it
      # would miss the change the lock holder just committed.
      def lock_entries(company_id, entry_ids)
        ids = Entry.where(company_id:, id: entry_ids.uniq).order(:id).lock("FOR UPDATE").pluck(:id)
        WriteSteps.reserved_rows(company_id, ids).values_at(*ids)
      end

      # Each entry's reservations in the form ReservationDecision reads, seen
      # from invoice_id. An id left out is one outside the company.
      def decision_reservations(company_id, entry_ids, invoice_id)
        found = Reservation.where(company_id:, entry_id: entry_ids).group_by(&:entry_id)
        entry_ids.index_with do |entry_id|
          found.fetch(entry_id, []).map do |reservation|
            { invoice: reservation.invoice_id == invoice_id ? :this : :other, state: reservation.state,
              disposition: reservation.disposition }
          end
        end
      end

      # locked mirrors whether the entry has any reservation, so each locked
      # entry whose flag changed is an entry change: its version rises, and it
      # gets one audit row and one outbox snapshot. A change that keeps the
      # flag, such as provisional to committed, writes none of them.
      def record_locked_flips(request, entries, generation)
        after = WriteSteps.reserved_rows(request.company_id, entries.map(&:id))
        flipped = entries.reject { |entry| after.fetch(entry.id).reserved == entry.reserved }
        checkpoint.call(:reservations_written)
        return if flipped.empty?

        flipped_ids = flipped.map(&:id)
        Entry.where(company_id: request.company_id, id: flipped_ids)
          .update_all(["version = version + 1, updated_at = ?", Time.current])
        rows = WriteSteps.reserved_rows(request.company_id, flipped_ids)
        checkpoint.call(:entry_written)
        WriteSteps.write_audit(company_id: request.company_id, actor: actor(request), action: request.route.to_s,
                               events: flipped.map { |entry| locked_event(entry) })
        checkpoint.call(:audit_written)
        WriteSteps.write_outbox(flipped_ids.map { |id| rows.fetch(id) }, generation)
        checkpoint.call(:outbox_written)
      end

      def locked_event(entry)
        { entry_id: entry.id, before: { "locked" => entry.reserved }, after: { "locked" => !entry.reserved },
          entry_created_at: entry.created_at }
      end

      def actor(request)
        { actor_type: ACTOR_TYPE, actor_name: request.actor_name }
      end

      def find_operation(request)
        InvoiceOperation.find_by(company_id: request.company_id, actor_name: request.actor_name,
                                 operation_id: request.operation_id)
      end

      # A prepare replayed with another invoice, disposition or entry set is
      # a reused key, not a replay.
      def prepare_replay(operation, request)
        same = [operation.invoice_id, operation.disposition, operation.desired_entry_ids] ==
               [request.invoice_id, request.disposition, request.entry_ids]
        same ? prepare_answer(operation) : WriteOutcome.refusal(:idempotency_key_reused)
      end

      def prepare_answer(operation)
        entries = operation.desired_entry_ids.map { |entry_id| { "entry_id" => entry_id, "company_id" => operation.company_id } }
        WriteOutcome.success(200, "operation_id" => operation.operation_id, "state" => operation.state, "entries" => entries)
      end

      # Another operation still prepared for this invoice must be committed or
      # aborted first; the caller retries it by the id this names.
      def unresolved_refusal(request)
        open = InvoiceOperation.find_by(company_id: request.company_id, invoice_id: request.invoice_id, state: PREPARED)
        return unless open

        WriteOutcome.success(Reasons.status(:unresolved_operation),
                             "reason" => "unresolved_operation", "operation_id" => open.operation_id, "retryable" => true)
      end

      def conflict_refusal(conflicts)
        body = conflicts.map { |conflict| { "entry_id" => conflict[:entry_id], "reason" => conflict[:reason].to_s } }
        WriteOutcome.success(Reasons.status(:conflict), "reason" => "conflict", "conflicts" => body)
      end

      def finish(request, payload)
        outcome = WriteOutcome.success(200, payload)
        ServiceIdempotencyReceipt.create!(
          company_id: request.company_id, actor_name: request.actor_name, operation: request.route.to_s,
          key: request.operation_id, fingerprint: fingerprint(request), status: outcome.status, body: outcome.body,
          created_at: Time.current
        )
        checkpoint.call(:receipt_written)
        outcome
      end

      def find_receipt(request)
        ServiceIdempotencyReceipt.find_by(company_id: request.company_id, actor_name: request.actor_name,
                                          operation: request.route.to_s, key: request.operation_id)
      end

      def receipt_answer(receipt, request)
        return WriteOutcome.refusal(:idempotency_key_reused) unless receipt.fingerprint == fingerprint(request)

        WriteOutcome.new(status: receipt.status, body: receipt.body)
      end

      # Commit and abort act only on what prepare stored, so the invoice is
      # all a replay must repeat; entries or a generation sent with the body
      # play no part.
      def fingerprint(request)
        Digest::SHA256.hexdigest(JSON.generate("invoice_id" => request.invoice_id))
      end
  end
end
