# frozen_string_literal: true

require "yaml"

module Invoices
  # The reservation adapter for entries the prepared monolith owns after a
  # rollback from the Timekeeping service (docs/architecture/timekeeping-soa.md
  # section 9.2). It runs the same steps as the service's
  # Timekeeping::ReservationOperations against the monolith's own
  # reservations, invoice_operations and entries tables, deciding each entry
  # with the shared Timekeeping::ReservationRules table.
  #
  # prepare runs inside the invoice transaction, so a rolled-back save undoes
  # its operation row and provisional reservations. commit and abort are
  # delivered later from the outbox; each locks the stored operation and acts
  # only while it is still prepared, so the first of them wins and a repeat
  # changes nothing. Provisional rows are selected by the operation's own id,
  # so another operation's provisional rows are never promoted or dropped.
  # Commit also replaces retained rows on the entries it claims and releases
  # the invoice's committed rows absent from the desired set, which earlier
  # operations may have written.
  #
  # An entry is locked exactly when a reservation row exists for it
  # (Timekeeping::LocalEntry::RESERVED). Each entry whose locked flag flips,
  # or that mark_billed bills, gets version + 1 and one snapshot in
  # entry_outbox_items. A stored entry the projection would refuse is never
  # published: the call rolls back and answers refused (prepare, mark_billed)
  # or retryable (commit, abort). Every query is limited to the request's
  # company.
  class PreparedReservations
    # The actor every invoice_operations row of this adapter carries; the
    # operation key is (company_id, actor_name, operation_id).
    ACTOR_NAME = "monolith-invoices"

    # The same lock the prepared store's entry writer (Timekeeping::LocalOwner)
    # takes on entries rows, so the two writers wait on each other in id order.
    ROW_LOCK = "FOR UPDATE"

    # The reservation port carries no invoice status, so commit applies the
    # desired set prepare stored as a draft's, as the service does. Keeping a
    # non-draft invoice's entries is the job of the boundary that builds that
    # set; a retained disposition releases nothing.
    WIRE_INVOICE_STATUS = TimekeepingRules::ReservationDecision::DRAFT_STATUS

    PROVISIONAL = TimekeepingRules::ReservationDecision::PROVISIONAL
    COMMITTED = TimekeepingRules::ReservationDecision::COMMITTED
    ACTIVE, RETAINED = ReservationRequest::DISPOSITIONS
    PREPARED = "prepared"
    ABORTED = "aborted"
    BILLED = "billed"

    UNRESOLVED_REASON = YAML.safe_load_file(Rails.root.join("contracts/timekeeping/reservations.yml"))
      .dig("errors", "unresolved_operation", "reason").freeze
    # The reason the Timekeeping service gives for the same refusal.
    UNPUBLISHABLE_REASON = "unpublishable_entry"

    # Raised inside a call's savepoint when an entry it changed would publish
    # a snapshot the projection refuses, so every row the call wrote rolls
    # back; rescued after the savepoint. Carries entry ids only.
    class UnpublishableEntries < StandardError
      attr_reader :entry_ids

      def initialize(entry_ids)
        @entry_ids = entry_ids
        super("unpublishable entries: #{entry_ids.join(', ')}")
      end
    end

    # The two tables have no other model in the monolith.
    class Reservation < ApplicationRecord
      self.table_name = "reservations"
    end

    class Operation < ApplicationRecord
      self.table_name = "invoice_operations"
    end

    private_constant :Reservation, :Operation, :UnpublishableEntries

    def prepare(request)
      ApplicationRecord.transaction(requires_new: true) do
        replay = find_operation(request).first
        next outcome(replay.state) if replay
        next unresolved if Operation.exists?(company_id: request.company_id, invoice_id: request.invoice_id, state: PREPARED)

        entries = lock_entries(request.company_id, request.entries)
        decisions = decide(request, entries)
        conflicts = conflicts_in(decisions)
        next outcome("refused", conflicts:) if conflicts.any?

        operation = Operation.create!(
          company_id: request.company_id, invoice_id: request.invoice_id, operation_id: request.operation_id,
          actor_name: ACTOR_NAME, state: PREPARED, desired_entry_ids: request.entries,
          disposition: request.disposition, generation: request.generation, created_at: Time.current
        )
        reserve_provisionally(operation, claimed_ids(decisions))
        record_locked_flips(request.company_id, entries, operation.generation)
        outcome(PREPARED, counts: { entries: request.entries.size })
      end
    rescue ActiveRecord::RecordNotUnique
      # A backstop: the invoice lock the coordinator holds and the unresolved
      # check normally stop a second prepared operation for one invoice, or a
      # second provisional row on one entry. The savepoint has rolled back
      # every row this prepare wrote.
      unresolved
    rescue UnpublishableEntries => error
      unpublishable(error)
    end

    # The same check as prepare, for a sent invoice whose lines gain entries:
    # it takes the same row locks so it waits on a concurrent prepare, and
    # writes nothing.
    def admit(request)
      ApplicationRecord.transaction(requires_new: true) do
        entries = lock_entries(request.company_id, request.entries)
        conflicts = conflicts_in(decide(request, entries))
        next outcome("refused", conflicts:) if conflicts.any?

        outcome(PREPARED, counts: { entries: entries.size })
      end
    end

    # Applies the desired set and disposition prepare stored. A missing or
    # already finished operation answers committed and changes nothing, so
    # the commit outbox row settles.
    def commit(request)
      finish(request, COMMITTED) do |operation|
        entries = lock_entries(operation.company_id,
                               own_provisional(operation).pluck(:entry_id) + invoice_committed(operation).pluck(:entry_id))
        claimed_ids = own_provisional(operation).pluck(:entry_id)
        held_ids = invoice_committed(operation).pluck(:entry_id)
        released_ids = TimekeepingRules::ReservationDecision.call(
          current: decision_reservations(operation.company_id, held_ids, operation.invoice_id),
          desired: operation.desired_entry_ids, disposition: operation.disposition, invoice_status: WIRE_INVOICE_STATUS
        )[:release]

        make_desired_set_the_reservation_set(operation, claimed_ids, released_ids)
        record_locked_flips(operation.company_id, entries, operation.generation)
        # A claimed entry this invoice already held is kept, not newly reserved.
        { reserved: (claimed_ids - held_ids).size, released: released_ids.size }
      end
    end

    # Drops this operation's provisional rows. A missing operation (a refused
    # prepare stores none) or an already finished one answers aborted and
    # changes nothing, so the abort outbox row settles.
    def abort(request)
      finish(request, ABORTED) do |operation|
        entries = lock_entries(operation.company_id, own_provisional(operation).pluck(:entry_id))
        dropped = own_provisional(operation).delete_all
        record_locked_flips(operation.company_id, entries, operation.generation)
        { dropped: }
      end
    end

    # Bills the request's kept entries that are not billed yet in the
    # prepared entries table; timesheet_entries is the projection the relay
    # writes from the snapshots. A repeated call finds nothing left to bill.
    def mark_billed(request)
      ApplicationRecord.transaction(requires_new: true) do
        entries = lock_entries(request.company_id, request.entries)
        billable_ids = entries.filter_map { |entry| entry.id if entry.discarded_at.nil? && entry.bill_status != BILLED }
        if billable_ids.any?
          Timekeeping::LocalEntry.where(company_id: request.company_id, id: billable_ids)
            .update_all(["bill_status = ?, version = version + 1, updated_at = ?", BILLED, Time.current])
          write_snapshots(request.company_id, billable_ids, request.generation)
        end
        outcome(COMMITTED, counts: { billed: billable_ids.size })
      end
    rescue UnpublishableEntries => error
      unpublishable(error)
    end

    private

      def find_operation(request)
        Operation.where(company_id: request.company_id, actor_name: ACTOR_NAME,
                        operation_id: request.operation_id, invoice_id: request.invoice_id)
      end

      # Locks the stored operation and, while it is still prepared, runs the
      # block and moves the operation to settled_state in the same
      # transaction. The block returns the counts to answer with. An entry
      # it would publish unpublishably leaves the operation prepared and
      # answers retryable, so the outbox row is delivered again once the
      # stored entry is repaired.
      def finish(request, settled_state)
        ApplicationRecord.transaction(requires_new: true) do
          operation = find_operation(request).lock.first
          next outcome(settled_state) unless operation&.state == PREPARED

          counts = yield operation
          operation.update!(state: settled_state, finished_at: Time.current)
          outcome(settled_state, counts:)
        end
      rescue UnpublishableEntries
        outcome("retryable", reason: UNPUBLISHABLE_REASON)
      end

      # The company's entries with these ids, discarded ones included, locked
      # in id order so two writers over the same entries wait in turn. The
      # reservation flag is read in a second statement once the locks are
      # held: a statement that waited on a lock still evaluates its
      # reservation subquery against the snapshot taken before the wait.
      def lock_entries(company_id, entry_ids)
        return [] if entry_ids.empty?

        ids = Timekeeping::LocalEntry.where(company_id:, id: entry_ids.uniq).order(:id).lock(ROW_LOCK).pluck(:id)
        reserved_rows(company_id, ids).values_at(*ids)
      end

      def reserved_rows(company_id, ids)
        Timekeeping::LocalEntry.with_reserved.where(company_id:, id: ids).index_by(&:id)
      end

      # Each requested entry with its prepare outcome and its committed
      # reservation row.
      def decide(request, entries)
        kept_ids = entries.filter_map { |entry| entry.id if entry.discarded_at.nil? }
        rows = Reservation.where(company_id: request.company_id, entry_id: request.entries).group_by(&:entry_id)
        claims = EntryClaims.new(request.company_id, request.entries)
        request.entries.map do |entry_id|
          committed = rows.fetch(entry_id, []).find { |row| row.state == COMMITTED }
          result = Timekeeping::ReservationRules.prepare_outcome({
            in_company: kept_ids.include?(entry_id),
            committed: committed_claim(committed) { claims.other_active_claim(entry_id, request.invoice_id) },
            provisional: rows.fetch(entry_id, []).any? { |row| row.state == PROVISIONAL },
            invoice_id: request.invoice_id
          })
          { entry_id:, result:, committed: }
        end
      end

      # The claim the rules see for one entry: an active committed row first,
      # then another kept invoice's active claim through its lines or holding,
      # then a retained row, this invoice's own included. A sent invoice's
      # added line passes admit and reserves nothing, so a row that only
      # retains the entry must not hide that line's claim, or a restored
      # invoice could take the entry back while the sent invoice holds it.
      def committed_claim(committed)
        row_claim = committed && { invoice_id: committed.invoice_id, disposition: committed.disposition }
        return row_claim if committed&.disposition == ACTIVE

        yield || row_claim
      end

      def conflicts_in(decisions)
        decisions.filter_map do |decision|
          { entry_id: decision[:entry_id], reason: decision[:result].to_s } if Timekeeping::ReservationRules.refusal?(decision[:result])
        end
      end

      # The free entries, plus the desired entries this invoice holds only as
      # a retained owner: a successor may take such an entry, so this
      # operation claims it with a provisional row as well, and whichever
      # operation prepares first holds it.
      def claimed_ids(decisions)
        decisions.filter_map do |decision|
          committed = decision[:committed]
          retained_by_this = decision[:result] == :keep && committed&.disposition == RETAINED
          decision[:entry_id] if decision[:result] == :add_provisional || retained_by_this
        end
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

      # Order matters for the one-committed-per-entry index: a retained
      # committed row on a claimed entry gives way first, whichever invoice
      # holds it (a predecessor's, or this invoice's own when it claims the
      # entry back), then the released rows go, then this operation's
      # provisional rows become committed, and every row the invoice holds
      # takes the operation's disposition. An active committed row is never
      # removed: prepare refuses such an entry to every other invoice.
      def make_desired_set_the_reservation_set(operation, claimed_ids, released_ids)
        Reservation.where(company_id: operation.company_id, entry_id: claimed_ids, state: COMMITTED,
                          disposition: RETAINED).delete_all
        invoice_committed(operation).where(entry_id: released_ids).delete_all
        own_provisional(operation).update_all(state: COMMITTED)
        invoice_committed(operation).update_all(disposition: operation.disposition)
      end

      def own_provisional(operation)
        Reservation.where(company_id: operation.company_id, invoice_operation_id: operation.id, state: PROVISIONAL)
      end

      def invoice_committed(operation)
        Reservation.where(company_id: operation.company_id, invoice_id: operation.invoice_id, state: COMMITTED)
      end

      # Each entry's reservations in the form ReservationDecision reads, seen
      # from invoice_id.
      def decision_reservations(company_id, entry_ids, invoice_id)
        found = Reservation.where(company_id:, entry_id: entry_ids).group_by(&:entry_id)
        entry_ids.index_with do |entry_id|
          found.fetch(entry_id, []).map do |row|
            { invoice: row.invoice_id == invoice_id ? :this : :other, state: row.state, disposition: row.disposition }
          end
        end
      end

      # entries were read with their reservation flag when locked. Each one
      # whose flag differs now gets version + 1 and one snapshot; a change
      # that keeps the flag, such as provisional to committed, writes none.
      def record_locked_flips(company_id, entries, generation)
        after = reserved_rows(company_id, entries.map(&:id))
        flipped_ids = entries.filter_map { |entry| entry.id unless after.fetch(entry.id).reserved == entry.reserved }
        return if flipped_ids.empty?

        Timekeeping::LocalEntry.where(company_id:, id: flipped_ids)
          .update_all(["version = version + 1, updated_at = ?", Time.current])
        write_snapshots(company_id, flipped_ids, generation)
      end

      def write_snapshots(company_id, entry_ids, generation)
        stored = reserved_rows(company_id, entry_ids)
        rows = entry_ids.map { |id| stored.fetch(id) }
        invalid = Timekeeping::EntryOutbox.invalid_fields(rows)
        raise UnpublishableEntries, invalid.keys if invalid.any?

        Timekeeping::EntryOutbox.write(rows, generation:)
      end

      def unpublishable(error)
        outcome("refused", conflicts: error.entry_ids.map { |entry_id| { entry_id:, reason: UNPUBLISHABLE_REASON } })
      end

      def unresolved
        outcome("retryable", reason: UNRESOLVED_REASON)
      end

      def outcome(state, conflicts: [], counts: {}, reason: nil)
        ReservationOutcome.new(state:, conflicts:, counts:, reason:)
      end
  end
end
