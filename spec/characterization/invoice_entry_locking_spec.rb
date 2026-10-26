# frozen_string_literal: true

require "rails_helper"

# Pins today's end state of timesheet entries after each invoice action that locks or
# unlocks them. Every example reloads the entries and checks `locked` and `bill_status`;
# none checks that a callback ran, because a later callback can undo an earlier unlock.
# Examples marked "deliberate fix pending: may change" are the only ones a later
# behaviour change is expected to flip.
RSpec.describe "Characterization: invoice timesheet entry locking", type: :request do
  let(:company) { create(:company) }
  let(:client) { create(:client, company:) }
  let(:project) { create(:project, client:, billable: true) }
  let(:entry_owner) { create(:user, current_workspace_id: company.id) }
  let(:admin) { create(:user, current_workspace_id: company.id) }

  before do
    create(:employment, company:, user: admin)
    admin.add_role :admin, company
    sign_in admin
  end

  def locking_spec_entry
    create(:timesheet_entry, user: entry_owner, project:, bill_status: "unbilled")
  end

  def locking_spec_direct_line(invoice)
    create(:invoice_line_item, invoice:, timesheet_entry: locking_spec_entry, rate: 100, quantity: 60)
  end

  # A project aggregate line has no direct entry; its entries are linked through join rows.
  def locking_spec_aggregate_line(invoice, linked_entries)
    line = create(:invoice_line_item, invoice:, timesheet_entry: nil, rate: 100, quantity: 120)
    linked_entries.each do |entry|
      create(:invoice_line_item_time_entry, invoice_line_item: line, timesheet_entry: entry)
    end
    line
  end

  # One direct line and one aggregate line with one linked entry; returns all their entries.
  def locking_spec_mixed_line_entries(invoice)
    line = locking_spec_direct_line(invoice)
    aggregate_entries = [locking_spec_entry]
    locking_spec_aggregate_line(invoice, aggregate_entries)
    [line.timesheet_entry] + aggregate_entries
  end

  def force_locked(entries, locked: true)
    entries.each { |entry| entry.update_columns(locked:) }
  end

  def expect_entries_state(entries, locked:, bill_status: "unbilled")
    entries.each do |entry|
      fresh = TimesheetEntry.find(entry.id)
      expect(fresh.locked).to be(locked), "entry #{entry.id}: expected locked #{locked}, got #{fresh.locked}"
      expect(fresh.bill_status).to eq(bill_status)
    end
  end

  def invoice_update_params(invoice, status:, line_items_attributes:)
    {
      invoice: {
        client_id: client.id,
        invoice_number: invoice.invoice_number,
        issue_date: invoice.issue_date.iso8601,
        due_date: invoice.due_date.iso8601,
        status:,
        currency: company.base_currency,
        invoice_line_items_attributes: line_items_attributes
      }
    }
  end

  def destroy_line_attributes(line)
    {
      id: line.id,
      name: line.name,
      date: line.date.iso8601,
      rate: line.rate,
      quantity: line.quantity,
      _destroy: true
    }
  end

  describe "draft line item edit that re-saves the invoice" do
    # Deliberate change: the per-save re-lock is retired. A totals-only re-save
    # changes no entry set, so it sends no reservation operation.
    it "keeps the draft's entries locked and writes no intent when the edit changes only the invoice totals" do
      invoice = create(:invoice, company:, client:)
      line = locking_spec_direct_line(invoice)
      aggregate_entries = [locking_spec_entry, locking_spec_entry]
      locking_spec_aggregate_line(invoice, aggregate_entries)
      entries = [line.timesheet_entry] + aggregate_entries
      expect_entries_state(entries, locked: true)
      amount_before = invoice.reload.amount
      intents_before = InvoiceOperationIntent.where(invoice_id: invoice.id).count

      InvoiceLineItem.find(line.id).update!(quantity: line.quantity + 60)

      expect(invoice.reload.amount).not_to eq(amount_before)
      expect_entries_state(entries, locked: true)
      expect(InvoiceOperationIntent.where(invoice_id: invoice.id).count).to eq(intents_before)
    end
  end

  describe "L4: aggregate line removed from a draft (deliberate fix pending: may change)" do
    it "leaves the linked entries locked when the line item is loaded fresh before destroy" do
      invoice = create(:invoice, company:, client:)
      linked_entries = [locking_spec_entry, locking_spec_entry]
      line = locking_spec_aggregate_line(invoice, linked_entries)
      force_locked(linked_entries)

      InvoiceLineItem.find(line.id).destroy!

      expect(InvoiceLineItem.exists?(line.id)).to be(false)
      expect_entries_state(linked_entries, locked: true)
    end

    it "unlocks the linked entries when linked_timesheet_entries is already loaded before destroy" do
      invoice = create(:invoice, company:, client:)
      linked_entries = [locking_spec_entry, locking_spec_entry]
      line = locking_spec_aggregate_line(invoice, linked_entries)
      force_locked(linked_entries)
      preloaded_line = InvoiceLineItem.includes(:linked_timesheet_entries).find(line.id)
      expect(preloaded_line.association(:linked_timesheet_entries)).to be_loaded

      preloaded_line.destroy!

      expect(InvoiceLineItem.exists?(line.id)).to be(false)
      expect_entries_state(linked_entries, locked: false)
    end

    it "leaves the linked entries locked when the line is removed with nested _destroy through the invoice update" do
      invoice = create(:invoice, company:, client:)
      linked_entries = [locking_spec_entry, locking_spec_entry]
      line = locking_spec_aggregate_line(invoice, linked_entries)
      force_locked(linked_entries)

      send_request :patch, api_v1_invoice_path(invoice),
        params: invoice_update_params(invoice, status: "draft", line_items_attributes: [destroy_line_attributes(line)]),
        headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(InvoiceLineItem.exists?(line.id)).to be(false)
      expect_entries_state(linked_entries, locked: true)
    end

    it "leaves the linked entries locked when the draft is bulk deleted" do
      invoice = create(:invoice, company:, client:)
      linked_entries = [locking_spec_entry, locking_spec_entry]
      locking_spec_aggregate_line(invoice, linked_entries)
      force_locked(linked_entries)

      send_request :post, api_v1_invoices_bulk_deletion_index_path,
        params: { invoices_ids: [invoice.id] },
        headers: auth_headers(admin)

      expect(response).to have_http_status(:no_content)
      expect(Invoice.exists?(invoice.id)).to be(false)
      expect_entries_state(linked_entries, locked: true)
    end
  end

  describe "L4: direct line removed from a draft" do
    it "unlocks the line's direct entry when the line item is loaded fresh before destroy" do
      invoice = create(:invoice, company:, client:)
      line = locking_spec_direct_line(invoice)
      force_locked([line.timesheet_entry])

      InvoiceLineItem.find(line.id).destroy!

      expect(InvoiceLineItem.exists?(line.id)).to be(false)
      expect_entries_state([line.timesheet_entry], locked: false)
    end
  end

  describe "L2: discarding a draft (deliberate fix pending: may change)" do
    it "ends with the draft's entries locked again" do
      invoice = create(:invoice, company:, client:)
      entries = locking_spec_mixed_line_entries(invoice)
      force_locked(entries)

      send_request :delete, api_v1_invoice_path(invoice), headers: auth_headers(admin)

      expect(response).to have_http_status(:success)
      expect(invoice.reload).to be_discarded
      expect_entries_state(entries, locked: true)
    end
  end

  describe "L3: discarding a non-draft" do
    it "leaves the invoice's entries locked" do
      invoice = create(:invoice, company:, client:, status: :sent)
      entries = locking_spec_mixed_line_entries(invoice)
      force_locked(entries)

      send_request :delete, api_v1_invoice_path(invoice), headers: auth_headers(admin)

      expect(response).to have_http_status(:success)
      expect(invoice.reload).to be_discarded
      expect_entries_state(entries, locked: true)
    end
  end

  describe "L4: line removed from a non-draft" do
    it "leaves the entries locked when the line item is destroyed" do
      invoice = create(:invoice, company:, client:, status: :sent)
      direct_line = locking_spec_direct_line(invoice)
      linked_entries = [locking_spec_entry]
      aggregate_line = locking_spec_aggregate_line(invoice, linked_entries)
      entries = [direct_line.timesheet_entry] + linked_entries
      force_locked(entries)

      InvoiceLineItem.find(direct_line.id).destroy!
      InvoiceLineItem.includes(:linked_timesheet_entries).find(aggregate_line.id).destroy!

      expect(InvoiceLineItem.exists?(direct_line.id)).to be(false)
      expect(InvoiceLineItem.exists?(aggregate_line.id)).to be(false)
      expect_entries_state(entries, locked: true)
    end

    it "leaves the entries locked when the line is removed from a sent invoice with nested _destroy" do
      invoice = create(:invoice, company:, client:, status: :sent)
      direct_line = locking_spec_direct_line(invoice)
      linked_entries = [locking_spec_entry]
      aggregate_line = locking_spec_aggregate_line(invoice, linked_entries)
      entries = [direct_line.timesheet_entry] + linked_entries
      force_locked(entries)

      send_request :patch, api_v1_invoice_path(invoice),
        params: invoice_update_params(
          invoice,
          status: "sent",
          line_items_attributes: [destroy_line_attributes(direct_line), destroy_line_attributes(aggregate_line)]
        ),
        headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(InvoiceLineItem.exists?(direct_line.id)).to be(false)
      expect(InvoiceLineItem.exists?(aggregate_line.id)).to be(false)
      expect_entries_state(entries, locked: true)
    end
  end

  describe "L6: sending an invoice" do
    it "leaves the entries locked and unbilled" do
      invoice = create(:invoice, company:, client:)
      entries = locking_spec_mixed_line_entries(invoice)
      force_locked(entries)

      send_request :post, send_invoice_api_v1_invoice_path(id: invoice.id),
        params: { invoice_email: { subject: "Invoice", recipients: [client.email], message: "Please pay" } },
        headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(invoice.reload).to be_sent
      expect_entries_state(entries, locked: true, bill_status: "unbilled")
    end
  end

  describe "bulk hard delete of a non-draft invoice" do
    it "removes the invoice and leaves its entries locked with no invoice (orphans)" do
      invoice = create(:invoice, company:, client:, status: :sent)
      entries = locking_spec_mixed_line_entries(invoice)
      force_locked(entries)

      send_request :post, api_v1_invoices_bulk_deletion_index_path,
        params: { invoices_ids: [invoice.id] },
        headers: auth_headers(admin)

      expect(response).to have_http_status(:no_content)
      expect(Invoice.exists?(invoice.id)).to be(false)
      expect(InvoiceLineItem.where(timesheet_entry_id: entries.map(&:id))).to be_empty
      expect(InvoiceLineItemTimeEntry.where(timesheet_entry_id: entries.map(&:id))).to be_empty
      expect_entries_state(entries, locked: true)
    end
  end
end
