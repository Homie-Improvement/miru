# frozen_string_literal: true

module Invoices
  # The reservation adapter for entries the monolith still owns. Its lock
  # store is `timesheet_entries.locked`. Which invoice claims an entry is read
  # from `invoice_entry_holdings` and from the lines of kept invoices
  # (Invoices::EntryClaims), because an invoice saved before holdings existed,
  # or a sent invoice that never locked, claims its entries only through its
  # lines.
  #
  # prepare runs in the invoice transaction: it locks the invoice's new
  # entries, takes over entries another invoice only retains, and records the
  # entries the operation removes. A rolled-back save undoes all of it, so
  # abort has nothing to undo. commit applies the recorded removals once per
  # operation_id, releasing only entries nothing still claims, so a late or
  # repeated commit never unlocks an entry held again since. admit applies the
  # same rules and writes nothing. Every query is limited to the request's
  # company.
  class LegacyReservations
    # Serializes adapter writers on each entry row without conflicting with
    # the FOR KEY SHARE that line-item validation takes on the same entries;
    # FOR UPDATE would deadlock two saves that validated the same entry.
    ROW_LOCK = "FOR NO KEY UPDATE"

    ACTIVE = ReservationRequest::DISPOSITIONS.first

    def prepare(request)
      ApplicationRecord.transaction do
        entry_ids = lock_entries(request.company_id, request.entries)
        claims = EntryClaims.new(request.company_id, request.entries)
        conflicts = conflicts_for(request, entry_ids, claims)
        next outcome("refused", conflicts:) if conflicts.any?

        set_locked(entry_ids, true) if request.disposition == ACTIVE
        take_over(request, claims, entry_ids)
        record_release(request, claims.held_by(request.invoice_id))
        outcome("prepared", counts: { entries: entry_ids.size })
      end
    end

    # The same check as prepare, for a save that changes no locks: it takes
    # the same row locks so it waits on a concurrent prepare, and writes
    # nothing.
    def admit(request)
      ApplicationRecord.transaction do
        entry_ids = lock_entries(request.company_id, request.entries)
        conflicts = conflicts_for(request, entry_ids, EntryClaims.new(request.company_id, request.entries))
        next outcome("refused", conflicts:) if conflicts.any?

        outcome("prepared", counts: { entries: entry_ids.size })
      end
    end

    def commit(request)
      ApplicationRecord.transaction do
        release = LegacyEntryRelease.lock.find_by(
          company_id: request.company_id, invoice_id: request.invoice_id,
          operation_id: request.operation_id, applied_at: nil
        )
        apply_release(release) if release
      end
      outcome("committed")
    end

    # Prepare writes only in the invoice transaction, so by the time an abort
    # is delivered a rollback has already undone it. Abort never unlocks: an
    # entry it would free may be held by another invoice.
    def abort(_request)
      outcome("aborted")
    end

    def mark_billed(request)
      ApplicationRecord.transaction do
        entry_ids = lock_entries(request.company_id, request.entries)
        # Selected again after the wait for the row locks, so an entry
        # discarded meanwhile is not billed.
        billed = TimesheetEntry.kept.where(id: entry_ids).update!(bill_status: :billed)
        outcome("committed", counts: { billed: billed.size })
      end
    end

    private

      # Locks the request company's rows in id order and returns their ids.
      # The facts that classify them are read afterwards, in new statements,
      # so they include what the previous lock holder committed.
      def lock_entries(company_id, entry_ids)
        return [] if entry_ids.empty?

        TimesheetEntry.where(company_id:, id: entry_ids).order(:id).lock(ROW_LOCK).pluck(:id)
      end

      def conflicts_for(request, entry_ids, claims)
        request.entries.filter_map do |entry_id|
          result = Timekeeping::ReservationRules.prepare_outcome({
            in_company: entry_ids.include?(entry_id),
            committed: claims.committed_claim(entry_id, request.invoice_id),
            provisional: false,
            invoice_id: request.invoice_id
          })
          { entry_id:, reason: result.to_s } if Timekeeping::ReservationRules.refusal?(result)
        end
      end

      def set_locked(entry_ids, locked)
        TimesheetEntry.where(id: entry_ids).update_all(locked:, updated_at: Time.current) if entry_ids.any?
      end

      # A successor that takes an entry drops the other invoices' claims that
      # give way to it, in the same transaction, so a rolled-back save leaves
      # those claims as they were. The entries are removed from each row's
      # current value in the database, not from the copy read earlier, so two
      # successors taking different entries from one holding keep both removals.
      def take_over(request, claims, taken_ids)
        holding_ids = claims.yielding_holdings(request.invoice_id, taken_ids).map(&:id)
        return if holding_ids.empty?

        InvoiceEntryHolding.where(company_id: request.company_id, id: holding_ids).update_all([<<~SQL.squish, taken_ids, Time.current])
          entry_ids = ARRAY(
            SELECT kept.entry_id FROM unnest(entry_ids) WITH ORDINALITY AS kept(entry_id, position)
            WHERE kept.entry_id <> ALL(ARRAY[?]::bigint[]) ORDER BY kept.position
          ),
          updated_at = ?
        SQL
      end

      def record_release(request, held_entry_ids)
        removed = held_entry_ids - request.entries
        return if removed.empty?

        LegacyEntryRelease.insert(
          { company_id: request.company_id, invoice_id: request.invoice_id,
            operation_id: request.operation_id, entry_ids: removed.sort, created_at: Time.current },
          unique_by: %i[company_id operation_id]
        )
      end

      def apply_release(release)
        candidates = lock_entries(release.company_id, release.entry_ids)
        claimed = EntryClaims.new(release.company_id, candidates).claimed_entry_ids
        set_locked(candidates - claimed, false)
        release.update!(applied_at: Time.current)
      end

      def outcome(state, conflicts: [], counts: {})
        ReservationOutcome.new(state:, conflicts:, counts:)
      end
  end
end
