# frozen_string_literal: true

module Invoices
  # What every reservation adapter (legacy, remote and prepared) receives for
  # prepare, commit, abort and mark_billed. The intent row stores this request
  # so a retry resends it unchanged; the request therefore keeps its own frozen
  # copy of the entries in one canonical form (unique Integers, ascending), and
  # a caller changing its array afterwards cannot change what is sent.
  ReservationRequest = Data.define(:company_id, :invoice_id, :operation_id, :generation, :disposition, :entries) do
    const_set(:DISPOSITIONS, %w[active retained].freeze)

    def self.canonical_entries(entries)
      Array(entries).map { |entry_id| Integer(entry_id) }.uniq.sort.freeze
    end

    def initialize(company_id:, invoice_id:, operation_id:, generation:, disposition:, entries:)
      # The request is the only value that carries the company across the
      # reservation port, so a request without one is refused here rather than
      # left for each adapter to notice.
      raise ArgumentError, "company_id is required" if company_id.nil?
      unless self.class::DISPOSITIONS.include?(disposition)
        raise ArgumentError, "unknown disposition #{disposition.inspect}"
      end

      super(
        company_id:,
        invoice_id:,
        operation_id: operation_id.dup.freeze,
        generation:,
        disposition: disposition.dup.freeze,
        entries: self.class.canonical_entries(entries)
      )
    end
  end
end
