# frozen_string_literal: true

module Timekeeping
  # A value snapshot of one company's invoice money, used to prove that moving
  # time-entry ownership left that money untouched. The audit log cannot prove
  # it: Invoice does not audit discount, tax or outstanding_amount, and line
  # items and invoice taxes are not audited at all.
  #
  # take only reads. It starts every query from the company, so another
  # company's rows can never appear, and it includes discarded invoices so a
  # change to any invoice row is caught. The printed PDF totals are read
  # without rendering the PDF, because the stored amount can differ from the
  # total the PDF prints.
  #
  # A snapshot is a frozen hash: { company_id:, values: { [kind, id, field] => value } }.
  # Values are BigDecimal, Integer, String or nil, never Float.
  class FinancialSnapshot
    INVOICE_FIELDS = %i[amount tax discount outstanding_amount].freeze
    LINE_ITEM_FIELDS = %i[invoice_id rate quantity].freeze
    # Every invoice_taxes column; timestamps are left out because they are not money.
    INVOICE_TAX_FIELDS = %i[invoice_id name calculation_method tax_configuration_id amount value].freeze
    PRINTED_INVOICE_FIELDS = %i[
      sub_total total invoice_amount invoice_tax invoice_amount_due invoice_amount_paid invoice_discount
    ].freeze

    # One changed value: which row and field, and its value before and after.
    # A row present on one side only has nil on the other side.
    Difference = Data.define(:company_id, :kind, :record_id, :field, :old_value, :new_value)

    def self.take(company_id:)
      new(company: Company.find(company_id)).take
    end

    def self.compare(before, after)
      unless before.fetch(:company_id) == after.fetch(:company_id)
        raise ArgumentError, "cannot compare snapshots of different companies"
      end

      company_id = before.fetch(:company_id)
      old_values = before.fetch(:values)
      new_values = after.fetch(:values)

      (old_values.keys | new_values.keys).sort.filter_map do |key|
        old_value = old_values[key]
        new_value = new_values[key]
        next if old_value == new_value

        kind, record_id, field = key
        Difference.new(company_id:, kind:, record_id:, field:, old_value:, new_value:)
      end
    end

    # Emits one signal per difference and returns the differences unchanged.
    # A list that mixes companies is refused before any signal is emitted, so
    # no report covers more than one company.
    def self.report(differences)
      if differences.map(&:company_id).uniq.size > 1
        raise ArgumentError, "cannot report differences of different companies together"
      end

      differences.each { |difference| Rails.event.notify(FinancialSnapshotChanged.new(difference)) }
    end

    def initialize(company:)
      @company = company
    end

    def take
      values = {}
      invoices.each { |invoice| add_invoice_values(values, invoice) }
      line_items.each { |line_item| add_row_values(values, :line_item, line_item, LINE_ITEM_FIELDS) }
      invoice_taxes.each { |invoice_tax| add_row_values(values, :invoice_tax, invoice_tax, INVOICE_TAX_FIELDS) }

      { company_id: company.id, values: values.transform_values(&:freeze).freeze }.freeze
    end

    private

      attr_reader :company

      def add_invoice_values(values, invoice)
        add_row_values(values, :invoice, invoice, INVOICE_FIELDS)

        printed = PdfGeneration::InvoiceService.printed_totals(invoice)
        PRINTED_INVOICE_FIELDS.each { |field| values[[:pdf_total, invoice.id, field]] = printed.fetch(field) }
        printed.fetch(:invoice_taxes).each do |invoice_tax|
          values[[:pdf_invoice_tax, invoice_tax.fetch(:id), :amount]] = invoice_tax.fetch(:amount)
        end
      end

      def add_row_values(values, kind, record, fields)
        fields.each { |field| values[[kind, record.id, field]] = record.public_send(field) }
      end

      # No kept scope: discarded invoices stay in the snapshot.
      def invoices
        @invoices ||= company.invoices.order(:id).to_a
      end

      def invoice_ids
        invoices.map(&:id)
      end

      def line_items
        InvoiceLineItem.where(invoice_id: invoice_ids).order(:id)
      end

      def invoice_taxes
        InvoiceTax.where(invoice_id: invoice_ids).order(:id)
      end
  end
end
