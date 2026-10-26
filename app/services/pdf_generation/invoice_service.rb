# frozen_string_literal: true

module PdfGeneration
  class InvoiceService < HtmlTemplateService
    attr_reader :invoice, :company_logo_url, :root_url

    def initialize(invoice, company_logo_url = nil, root_url = nil)
      @invoice = invoice
      @company_logo_url = company_logo_url
      @root_url = root_url

      super(
        "pdfs/invoices",
        layout: "layouts/pdf",
        locals: build_invoice_locals,
        options: invoice_pdf_options,
        root_url: root_url
      )
    end

    # The totals the PDF prints, without rendering it. Building an instance
    # renders the template, so this is a class method.
    def self.printed_totals(invoice)
      InvoiceTotals.new(invoice).printed
    end

    private

      def build_invoice_locals
        totals = self.class.printed_totals(invoice)

        {
          invoice: invoice,
          **totals.except(:invoice_taxes),
          company_logo: company_logo_url || "",
          client: invoice.client,
          invoice_line_items: build_line_items,
          invoice_taxes: totals[:invoice_taxes].map { |invoice_tax| invoice_tax.slice(:name, :amount) },
          signature_url: resolve_signature_url
        }
      end

      def build_line_items
        invoice.invoice_line_items.map do |item|
          InvoiceLineItemPresenter.new(item).pdf_row(invoice.currency)
        end
      end

      def calculate_subtotal
        invoice_totals.subtotal
      end

      def calculate_total(subtotal = calculate_subtotal)
        invoice_totals.total(subtotal)
      end

      def invoice_totals
        InvoiceTotals.new(invoice)
      end

      def resolve_signature_url
        company = invoice.company
        client = invoice.client

        return nil unless client.signature_enabled?
        return nil unless company.invoice_signature.attached?

        signature_path = Rails.application.routes.url_helpers.polymorphic_url(
          company.invoice_signature,
          only_path: true
        )
        return signature_path if root_url.blank?

        "#{root_url.delete_suffix('/')}#{signature_path}"
      rescue StandardError
        nil
      end

      def invoice_pdf_options
        {
          format: "A4",
          margin: {
            top: 18,
            bottom: 18,
            left: 18,
            right: 18
          },
          print_background: true,
          prefer_css_page_size: false
        }
      end
  end
end
