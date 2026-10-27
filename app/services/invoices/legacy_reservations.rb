# frozen_string_literal: true

module Invoices
  # The reservation adapter for entries the monolith still owns. Its lock
  # store is `timesheet_entries.locked`. Which invoice claims an entry is read
  # from `invoice_entry_holdings` and from the lines of kept invoices, because
  # an invoice saved before holdings existed, or a sent invoice that never
  # locked, claims its entries only through its lines.
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

    ACTIVE, RETAINED = ReservationRequest::DISPOSITIONS

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
        TimesheetEntry.kept.where(id: entry_ids).update!(bill_status: :billed)
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

      # What the invoices of one company claim on a set of entries: the
      # holdings that list them, and the lines of kept invoices that
      # reference them.
      #
      # Both are read in one statement, so they come from one snapshot. A
      # sent invoice that loses a line moves its claim from the line to a new
      # holding in one transaction, without the entry row lock; read in two
      # statements, that commit could fall between them and the claim would
      # be in neither read.
      class EntryClaims
        Holding = Data.define(:id, :invoice_id, :entry_ids, :disposition, :kept) do
          def active_and_kept? = kept && disposition == ACTIVE
        end

        CLAIMS_SQL = <<~SQL.squish
          WITH kept_invoices AS (
            SELECT id FROM invoices WHERE company_id = :company_id AND discarded_at IS NULL
          )
          SELECT holdings.id AS holding_id, holdings.invoice_id, holdings.entry_ids, holdings.disposition,
            holdings.invoice_id IN (SELECT id FROM kept_invoices) AS kept
          FROM invoice_entry_holdings AS holdings
          WHERE holdings.company_id = :company_id AND holdings.entry_ids && ARRAY[:entry_ids]::bigint[]
          UNION ALL
          SELECT NULL::bigint, lines.invoice_id, ARRAY[lines.timesheet_entry_id], NULL::varchar, TRUE
          FROM invoice_line_items AS lines
          WHERE lines.invoice_id IN (SELECT id FROM kept_invoices) AND lines.timesheet_entry_id IN (:entry_ids)
          UNION ALL
          SELECT NULL::bigint, lines.invoice_id, ARRAY[links.timesheet_entry_id], NULL::varchar, TRUE
          FROM invoice_line_item_time_entries AS links
          JOIN invoice_line_items AS lines ON lines.id = links.invoice_line_item_id
          WHERE lines.invoice_id IN (SELECT id FROM kept_invoices) AND links.timesheet_entry_id IN (:entry_ids)
          ORDER BY invoice_id
        SQL

        def initialize(company_id, entry_ids)
          @company_id = company_id
          @entry_ids = entry_ids
          @holdings, @line_references = read_claims
        end

        def held_by(invoice_id)
          InvoiceEntryHolding.find_by(company_id:, invoice_id:)&.entry_ids || []
        end

        # The reservation the rules see for one entry, in priority order: this
        # invoice's own holding, an active holding of another kept invoice,
        # another kept invoice's lines, this invoice's own lines, then a claim
        # that only retains it.
        def committed_claim(entry_id, invoice_id)
          listing = holdings.select { |holding| holding.entry_ids.include?(entry_id) }
          own = listing.find { |holding| holding.invoice_id == invoice_id }
          return { invoice_id:, disposition: own.disposition } if own

          active = listing.find(&:active_and_kept?)
          return { invoice_id: active.invoice_id, disposition: ACTIVE } if active

          referencing = line_references.fetch(entry_id, [])
          other = referencing.find { |referencing_id| referencing_id != invoice_id }
          return { invoice_id: other, disposition: ACTIVE } if other
          return { invoice_id:, disposition: ACTIVE } if referencing.include?(invoice_id)
          return { invoice_id: listing.first.invoice_id, disposition: RETAINED } if listing.any?

          nil
        end

        # Holdings of other invoices that give way when the given entries are
        # taken: every holding except an active one of a kept invoice.
        def yielding_holdings(invoice_id, taken_ids)
          return [] if taken_ids.empty?

          holdings.filter_map do |holding|
            next if holding.invoice_id == invoice_id || holding.active_and_kept?

            holding if holding.entry_ids.intersect?(taken_ids)
          end
        end

        def claimed_entry_ids
          (holdings.flat_map(&:entry_ids) + line_references.keys) & entry_ids
        end

        private

          attr_reader :company_id, :entry_ids, :holdings, :line_references

          # Returns the holdings, and entry id => ids of kept invoices whose
          # direct or grouped lines reference it. A line row has no holding id.
          def read_claims
            return [[], {}] if entry_ids.empty?

            sql = ApplicationRecord.sanitize_sql_array([CLAIMS_SQL, { company_id:, entry_ids: }])
            rows = ApplicationRecord.connection.select_all(sql, "Invoice entry claims").cast_values
            holding_rows, line_rows = rows.partition(&:first)
            holdings = holding_rows.map do |id, invoice_id, ids, disposition, kept|
              Holding.new(id:, invoice_id:, entry_ids: ids, disposition:, kept:)
            end
            references = line_rows.group_by { |row| row[2].first }
              .transform_values { |rows_for_entry| rows_for_entry.map { |row| row[1] }.uniq.sort }
            [holdings, references]
          end
      end
  end
end
