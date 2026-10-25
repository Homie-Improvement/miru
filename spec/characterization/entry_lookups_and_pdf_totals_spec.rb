# frozen_string_literal: true

require "rails_helper"

# Pins two read paths the Timekeeping extraction must keep:
# - the entry ids a draft line item unlocks on destroy (`TimesheetEntry.where(id:)`, no
#   company filter) and the ids the new-line-items picker hides as already allocated
#   (`filtered_ids`, built from every company's kept invoices) give the same result for
#   one company;
# - the invoice PDF prints a subtotal rounded to 3 places and an unrounded total, while
#   the stored `amount` is rounded to 2 places.
RSpec.describe "Characterization: entry lookups and PDF totals", type: :model do
  def lookup_spec_workspace
    company = create(:company)
    client = create(:client, company:)
    project = create(:project, client:, billable: true)
    user = create(:user, current_workspace_id: company.id)
    { company:, client:, project:, user: }
  end

  def lookup_spec_entry(workspace)
    create(:timesheet_entry, user: workspace[:user], project: workspace[:project], bill_status: "unbilled")
  end

  # A draft invoice with one direct line and one project aggregate line of two linked entries.
  def lookup_spec_allocated_lines(workspace)
    invoice = create(:invoice, company: workspace[:company], client: workspace[:client])
    direct_line = create(:invoice_line_item, invoice:, timesheet_entry: lookup_spec_entry(workspace))
    aggregate_line = create(:invoice_line_item, invoice:, timesheet_entry: nil)
    2.times do
      create(:invoice_line_item_time_entry, invoice_line_item: aggregate_line, timesheet_entry: lookup_spec_entry(workspace))
    end
    [direct_line, aggregate_line]
  end

  describe "X1 and X2 lookups for one company" do
    it "give the same allocated entry ids, and the picker shows only the unallocated entry" do
      first = lookup_spec_workspace
      second = lookup_spec_workspace
      first_lines = lookup_spec_allocated_lines(first)
      second_lines = lookup_spec_allocated_lines(second)
      free_entry = lookup_spec_entry(first)

      x1_ids = first_lines.flat_map do |line|
        fresh_line = InvoiceLineItem.find(line.id)
        TimesheetEntry.where(id: fresh_line.send(:associated_timesheet_entry_ids)).ids
      end
      second_company_ids = second_lines.flat_map do |line|
        InvoiceLineItem.find(line.id).send(:associated_timesheet_entry_ids)
      end

      service = GenerateInvoice::NewLineItemsService.new(first[:client], {})
      x2_ids_for_first = TimesheetEntry.where(id: service.send(:filtered_ids), project_id: first[:project].id).ids

      expect(x1_ids).to match_array(x2_ids_for_first)
      expect(x1_ids.size).to eq(3)
      expect(x1_ids & second_company_ids).to be_empty

      shown_ids = service.process[:new_line_item_entries].pluck(:timesheet_entry_id)
      expect(shown_ids).to eq([free_entry.id])
    end
  end

  describe "invoice PDF totals against the stored amount (M1)" do
    it "prints a 3-place subtotal and an unrounded total while the stored amount has 2 places" do
      workspace = lookup_spec_workspace
      invoice = create(:invoice, company: workspace[:company], client: workspace[:client], currency: "USD", tax: BigDecimal("0.01"), discount: 0)
      # One minute at rate 1 costs 1/60 = 0.01666..., which rounds to 0.017 (PDF) and 0.02 (stored).
      # With 0.01 tax the PDF total stays 0.027, while the stored amount is (0.02 + 0.01) = 0.03.
      create(:invoice_line_item, invoice:, timesheet_entry: lookup_spec_entry(workspace), quantity: 1, rate: 1)

      invoice.reload
      expect(invoice.amount).to eq(BigDecimal("0.03"))

      pdf_service = PdfGeneration::InvoiceService.new(invoice)
      expect(pdf_service.send(:calculate_subtotal)).to eq(BigDecimal("0.017"))
      expect(pdf_service.send(:calculate_total)).to eq(BigDecimal("0.027"))
      expect(pdf_service.locals[:sub_total]).to eq(FormatAmountService.new("USD", BigDecimal("0.017")).process)
      expect(pdf_service.locals[:total]).to eq(FormatAmountService.new("USD", BigDecimal("0.027")).process)
      expect(pdf_service.locals[:invoice_amount]).to eq(FormatAmountService.new("USD", BigDecimal("0.03")).process)
    end
  end
end
