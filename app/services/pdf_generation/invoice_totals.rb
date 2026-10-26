# frozen_string_literal: true

module PdfGeneration
  # The money values the invoice PDF prints, computed from the invoice alone.
  # It renders nothing, so callers that only need the printed totals (such as
  # a financial snapshot) can read them without building the PDF.
  class InvoiceTotals
    attr_reader :invoice

    def initialize(invoice)
      @invoice = invoice
    end

    # Formatted strings exactly as the PDF prints them. Each invoice tax also
    # carries its id so callers can key it; the PDF itself shows name and amount.
    def printed
      # Read the subtotal once so the printed total is always derived from the
      # printed subtotal, even if line items change between two reads.
      printed_subtotal = subtotal
      {
        **formatted_invoice_amounts,
        sub_total: format_currency(printed_subtotal),
        total: format_currency(total(printed_subtotal)),
        invoice_taxes: printed_invoice_taxes
      }
    end

    def subtotal
      invoice.invoice_line_items.total_cost_of_all_line_items
    end

    def total(subtotal = self.subtotal)
      tax = invoice.tax || 0
      discount = invoice.discount || 0
      subtotal + tax - discount
    end

    private

      def printed_invoice_taxes
        invoice.invoice_taxes.map do |invoice_tax|
          {
            id: invoice_tax.id,
            name: invoice_tax.name,
            amount: format_currency(invoice_tax.amount)
          }
        end
      end

      def formatted_invoice_amounts
        {
          invoice_amount: format_currency(invoice.amount),
          invoice_tax: format_currency(invoice.tax),
          invoice_amount_due: format_currency(invoice.amount_due),
          invoice_amount_paid: format_currency(invoice.amount_paid),
          invoice_discount: format_currency(invoice.discount)
        }
      end

      def format_currency(amount)
        FormatAmountService.new(invoice.currency, amount).process
      end
  end
end
