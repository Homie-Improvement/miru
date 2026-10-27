# frozen_string_literal: true

module Invoices
  # What the invoices of one company claim on a set of entries: the holdings
  # that list them, and the lines of kept invoices that reference them.
  #
  # Both are read in one statement, so they come from one snapshot. A sent
  # invoice that loses a line moves its claim from the line to a new holding
  # in one transaction, without the entry row lock; read in two statements,
  # that commit could fall between them and the claim would be in neither
  # read.
  class EntryClaims
    ACTIVE, RETAINED = ReservationRequest::DISPOSITIONS

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
      listing = listing_for(entry_id)
      own = listing.find { |holding| holding.invoice_id == invoice_id }
      return { invoice_id:, disposition: own.disposition } if own

      other = other_active_claim(entry_id, invoice_id)
      return other if other

      referencing = line_references.fetch(entry_id, [])
      return { invoice_id:, disposition: ACTIVE } if referencing.include?(invoice_id)
      return { invoice_id: listing.first.invoice_id, disposition: RETAINED } if listing.any?

      nil
    end

    # Another kept invoice's active claim on the entry, through an active
    # holding or through its direct or grouped lines; nil when there is none.
    def other_active_claim(entry_id, invoice_id)
      active = listing_for(entry_id).find { |holding| holding.invoice_id != invoice_id && holding.active_and_kept? }
      return { invoice_id: active.invoice_id, disposition: ACTIVE } if active

      other = line_references.fetch(entry_id, []).find { |referencing_id| referencing_id != invoice_id }
      { invoice_id: other, disposition: ACTIVE } if other
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

      def listing_for(entry_id)
        holdings.select { |holding| holding.entry_ids.include?(entry_id) }
      end

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
