# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Invoices#update", type: :request do
  let_it_be(:company) { create(:company, :with_logo) }
  let_it_be(:client) { create(:client, company:) }
  let(:user) { create(:user, current_workspace_id: company.id) }
  let(:invoice) { create(:invoice, company:, client:, invoice_number: "INV-UP-001") }

  before do
    create(:employment, company:, user:)
    user.add_role :admin, company
    sign_in user
  end

  it "removes deleted line items and preserves kept ones" do
    kept_line_item = create(:invoice_line_item,
      invoice:,
      timesheet_entry: nil,
      name: "Keep me",
      description: "Keep description",
      rate: 100,
      quantity: 60)
    removed_line_item = create(:invoice_line_item,
      invoice:,
      timesheet_entry: nil,
      name: "Remove me",
      description: "Remove description",
      rate: 50,
      quantity: 30)

    send_request :patch, api_v1_invoice_path(invoice), params: {
      invoice: {
        client_id: client.id,
        invoice_number: "INV-UP-001",
        issue_date: invoice.issue_date.iso8601,
        due_date: invoice.due_date.iso8601,
        status: "draft",
        currency: company.base_currency,
        invoice_line_items_attributes: [
          {
            id: kept_line_item.id,
            name: "Keep me",
            description: "Keep description updated",
            date: kept_line_item.date.iso8601,
            rate: 125,
            quantity: 90
          },
          {
            id: removed_line_item.id,
            name: "Remove me",
            description: "Remove description",
            date: removed_line_item.date.iso8601,
            rate: 50,
            quantity: 30,
            _destroy: true
          }
        ]
      }
    }, headers: auth_headers(user)

    expect(response).to have_http_status(:ok)

    invoice.reload
    expect(invoice.invoice_line_items.pluck(:name)).to eq(["Keep me"])

    kept_line_item.reload
    expect(kept_line_item.description).to eq("Keep description updated")
    expect(kept_line_item.rate).to eq(125)
    expect(kept_line_item.quantity).to eq(90)
    expect(invoice.invoice_line_items.find_by(id: removed_line_item.id)).to be_nil
  end

  it "updates an existing line item and creates a new one without duplicating the existing record" do
    existing_line_item = create(:invoice_line_item,
      invoice:,
      timesheet_entry: nil,
      name: "Existing item",
      description: "Existing description",
      rate: 100,
      quantity: 60)

    send_request :patch, api_v1_invoice_path(invoice), params: {
      invoice: {
        client_id: client.id,
        invoice_number: "INV-UP-001",
        issue_date: invoice.issue_date.iso8601,
        due_date: invoice.due_date.iso8601,
        status: "draft",
        currency: company.base_currency,
        invoice_line_items_attributes: [
          {
            id: existing_line_item.id,
            name: "Existing item updated",
            description: "Existing description updated",
            date: existing_line_item.date.iso8601,
            rate: 125,
            quantity: 90
          },
          {
            name: "New item",
            description: "New line item",
            date: Date.current.iso8601,
            rate: 80,
            quantity: 30
          }
        ]
      }
    }, headers: auth_headers(user)

    expect(response).to have_http_status(:ok)

    invoice.reload
    existing_line_item.reload

    expect(invoice.invoice_line_items.count).to eq(2)
    expect(invoice.invoice_line_items.group(:name).count).to eq(
      "Existing item updated" => 1,
      "New item" => 1
    )
    expect(existing_line_item.description).to eq("Existing description updated")
    expect(existing_line_item.rate).to eq(125)
    expect(existing_line_item.quantity).to eq(90)
  end

  it "recalculates totals after deleting one line item, updating another, and adding a new one" do
    kept_line_item = create(:invoice_line_item,
      invoice:,
      timesheet_entry: nil,
      name: "Keep me",
      description: "Keep description",
      rate: 100,
      quantity: 60)
    removed_line_item = create(:invoice_line_item,
      invoice:,
      timesheet_entry: nil,
      name: "Remove me",
      description: "Remove description",
      rate: 80,
      quantity: 30)

    send_request :patch, api_v1_invoice_path(invoice), params: {
      invoice: {
        client_id: client.id,
        invoice_number: "INV-UP-001",
        issue_date: invoice.issue_date.iso8601,
        due_date: invoice.due_date.iso8601,
        status: "draft",
        currency: company.base_currency,
        discount: 15,
        tax: 5,
        invoice_line_items_attributes: [
          {
            id: kept_line_item.id,
            name: "Keep me",
            description: "Keep description updated",
            date: kept_line_item.date.iso8601,
            rate: 120,
            quantity: 90
          },
          {
            id: removed_line_item.id,
            name: "Remove me",
            description: "Remove description",
            date: removed_line_item.date.iso8601,
            rate: 80,
            quantity: 30,
            _destroy: true
          },
          {
            name: "Add me",
            description: "New line item",
            date: Date.current.iso8601,
            rate: 70,
            quantity: 60
          }
        ]
      }
    }, headers: auth_headers(user)

    expect(response).to have_http_status(:ok)

    invoice.reload
    expect(invoice.invoice_line_items.find_by(id: removed_line_item.id)).to be_nil
    expect(invoice.amount.to_f).to eq(240.0)
    expect(invoice.amount_due.to_f).to eq(240.0)
    expect(json_response["amount"].to_f).to eq(240.0)
    expect(json_response["amountDue"].to_f).to eq(240.0)
  end

  it "recalculates configured taxes while the invoice is a draft" do
    tax_configuration = create(:tax_configuration, company:, name: "GST", calculation_method: "percentage", value: 10)
    line_item = create(:invoice_line_item,
      invoice:,
      timesheet_entry: nil,
      name: "Taxable item",
      description: "Original line item",
      rate: 100,
      quantity: 60)
    create(:invoice_tax, invoice:, tax_configuration:, name: "GST", calculation_method: "percentage", value: 10, amount: 10)

    send_request :patch, api_v1_invoice_path(invoice), params: {
      invoice: {
        client_id: client.id,
        invoice_number: "INV-UP-001",
        issue_date: invoice.issue_date.iso8601,
        due_date: invoice.due_date.iso8601,
        status: "draft",
        currency: company.base_currency,
        invoice_taxes_attributes: [
          {
            id: invoice.invoice_taxes.first.id,
            tax_configuration_id: tax_configuration.id,
            name: "GST",
            calculation_method: "percentage",
            value: 10
          }
        ],
        invoice_line_items_attributes: [
          {
            id: line_item.id,
            name: "Taxable item",
            description: "Original line item",
            date: line_item.date.iso8601,
            rate: 200,
            quantity: 120
          }
        ]
      }
    }, headers: auth_headers(user)

    expect(response).to have_http_status(:ok)

    invoice.reload
    expect(invoice.tax.to_f).to eq(40.0)
    expect(invoice.amount.to_f).to eq(440.0)
    expect(invoice.invoice_taxes.first.amount.to_f).to eq(40.0)
  end

  it "preserves configured tax snapshots once the invoice is sent" do
    tax_configuration = create(:tax_configuration, company:, name: "GST", calculation_method: "percentage", value: 10)
    sent_invoice = create(:invoice, company:, client:, status: :sent, invoice_number: "INV-SENT-TAX-001")
    line_item = create(:invoice_line_item,
      invoice: sent_invoice,
      timesheet_entry: nil,
      name: "Sent item",
      description: "Frozen tax line item",
      rate: 100,
      quantity: 60)
    invoice_tax = create(:invoice_tax,
      invoice: sent_invoice,
      tax_configuration:,
      name: "GST",
      calculation_method: "percentage",
      value: 10,
      amount: 10)
    sent_invoice.update_columns(tax: 10, amount: 110, amount_due: 110, outstanding_amount: 110)

    send_request :patch, api_v1_invoice_path(sent_invoice), params: {
      invoice: {
        client_id: client.id,
        invoice_number: "INV-SENT-TAX-001",
        issue_date: sent_invoice.issue_date.iso8601,
        due_date: sent_invoice.due_date.iso8601,
        status: "sent",
        currency: company.base_currency,
        invoice_taxes_attributes: [
          {
            id: invoice_tax.id,
            tax_configuration_id: tax_configuration.id,
            name: "GST",
            calculation_method: "percentage",
            value: 10,
            amount: 10
          }
        ],
        invoice_line_items_attributes: [
          {
            id: line_item.id,
            name: "Sent item",
            description: "Frozen tax line item",
            date: line_item.date.iso8601,
            rate: 200,
            quantity: 120
          }
        ]
      }
    }, headers: auth_headers(user)

    expect(response).to have_http_status(:ok)

    sent_invoice.reload
    expect(sent_invoice.invoice_taxes.first.amount.to_f).to eq(10.0)
    expect(sent_invoice.tax.to_f).to eq(10.0)
    expect(sent_invoice.amount.to_f).to eq(410.0)
  end

  it "returns company data needed by the editor preview" do
    company.addresses.first.update!(address_line_1: "100 Market St", city: "San Francisco", state: "CA", country: "USA", pin: "94105")
    company.update!(
      business_phone: "+14155552671",
      tax_id: "TAX-123",
      bank_name: "QA Bank",
      bank_account_number: "12345678",
      bank_routing_number: "987654321",
      bank_swift_code: "QABKUS33",
      ein: "12-3456789",
      us_taxpayer_id: "US-TIN-1234"
    )

    send_request :patch, api_v1_invoice_path(invoice), params: {
      invoice: {
        client_id: client.id,
        invoice_number: "INV-UP-001",
        issue_date: invoice.issue_date.iso8601,
        due_date: invoice.due_date.iso8601,
        status: "draft",
        currency: company.base_currency,
        invoice_line_items_attributes: [
          {
            name: "Updated item",
            description: "Updated line item",
            date: Date.current.iso8601,
            rate: 80,
            quantity: 60
          }
        ]
      }
    }, headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    expect(json_response.dig("company", "name")).to eq(company.name)
    expect(json_response.dig("company", "phoneNumber")).to eq(company.business_phone)
    expect(json_response.dig("company", "taxId")).to eq(company.tax_id)
    expect(json_response.dig("company", "ein")).to eq(company.ein)
    expect(json_response.dig("company", "usTaxpayerId")).to eq(company.us_taxpayer_id)
    expect(json_response.dig("company", "logo")).to end_with(company.company_logo)
    expect(json_response.dig("company", "bankName")).to eq(company.bank_name)
    expect(json_response.dig("company", "bankAccountNumber")).to eq(company.bank_account_number)
    expect(json_response.dig("company", "bankRoutingNumber")).to eq(company.bank_routing_number)
    expect(json_response.dig("company", "bankSwiftCode")).to eq(company.bank_swift_code)
    expect(
      json_response.dig("company", "address", "addressLine1") ||
      json_response.dig("company", "address", "address_line_1")
    ).to eq(company.current_address.address_line_1)
  end
end

# Generated by Descant: acceptance tests.
RSpec.describe "Api::V1::Invoices#update of a sent invoice over a kept draft's entry", type: :request do
  let(:sent_update_company) { create(:company, base_currency: "USD") }
  let(:sent_update_client) { create(:client, company: sent_update_company) }
  let(:sent_update_admin) { create(:user, current_workspace_id: sent_update_company.id) }
  let(:sent_update_project) { create(:project, client: sent_update_client, billable: true) }

  before do
    create(:employment, company: sent_update_company, user: sent_update_admin)
    sent_update_admin.add_role :admin, sent_update_company
    sign_in sent_update_admin
  end

  # "a second kept invoice on the same entry fails with \"entry is on another invoice\""
  it "adding an entry held by a kept draft to a sent invoice is refused and the sent invoice is unchanged" do
    entry = create(:timesheet_entry, user: sent_update_admin, project: sent_update_project,
      bill_status: :unbilled, locked: false, work_date: Date.current, duration: 60)
    draft = create(:invoice, company: sent_update_company, client: sent_update_client)
    create(:invoice_line_item, invoice: draft, timesheet_entry: entry, rate: 100, quantity: 60)
    sent = create(:invoice, company: sent_update_company, client: sent_update_client, status: :sent,
      invoice_number: "INV-SENT-UPD-001")

    expect do
      send_request :patch, api_v1_invoice_path(sent), params: {
        invoice: {
          client_id: sent_update_client.id,
          invoice_number: sent.invoice_number,
          issue_date: sent.issue_date.iso8601,
          due_date: sent.due_date.iso8601,
          status: "sent",
          currency: sent_update_company.base_currency,
          invoice_line_items_attributes: [
            { name: "Same work", description: "dup", date: Date.current.iso8601, rate: 100, quantity: 60,
              timesheet_entry_id: entry.id }
          ]
        }
      }, headers: auth_headers(sent_update_admin)
    end.to not_change(InvoiceLineItem, :count).and not_change(InvoiceOperationIntent, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("entry is on another invoice")
    expect(response.body).not_to include(draft.invoice_number)
    expect(sent.reload.invoice_line_items).to be_empty
    expect(entry.reload.locked).to be(true)
  end
end

RSpec.describe "Api::V1::Invoices#update with nested entry lines", type: :request do
  let(:nested_company) { create(:company) }
  let(:nested_client) { create(:client, company: nested_company) }
  let(:nested_project) { create(:project, client: nested_client, billable: true) }
  let(:nested_user) { create(:user, current_workspace_id: nested_company.id) }

  before do
    create(:employment, company: nested_company, user: nested_user)
    nested_user.add_role :admin, nested_company
    sign_in nested_user
  end

  # "Nested `invoice_line_items_attributes` on create or update produce exactly one operation per request."
  it "a nested draft update adding two entry lines writes exactly one intent" do
    invoice = create(:invoice, company: nested_company, client: nested_client, invoice_number: "INV-NESTED-1")
    entries = Array.new(2) do
      create(:timesheet_entry, user: nested_user, project: nested_project, bill_status: "unbilled")
    end
    line_items = entries.map do |entry|
      { name: "Entry", description: "line", date: Date.current.iso8601, rate: 100, quantity: 60, timesheet_entry_id: entry.id }
    end

    expect do
      send_request :patch, api_v1_invoice_path(invoice), params: {
        invoice: {
          client_id: nested_client.id, invoice_number: "INV-NESTED-1",
          issue_date: invoice.issue_date.iso8601, due_date: invoice.due_date.iso8601,
          status: "draft", currency: nested_company.base_currency, invoice_line_items_attributes: line_items
        }
      }, headers: auth_headers(nested_user)
    end.to change { InvoiceOperationIntent.where(invoice_id: invoice.id).count }.by(1)

    expect(response).to have_http_status(:ok)
    expect(entries.map { |entry| entry.reload.locked }).to eq([true, true])
  end
end

RSpec.describe "Api::V1::Invoices#update over an unlocked sent invoice's entry", type: :request do
  let(:unlocked_link_company) { create(:company, base_currency: "USD") }
  let(:unlocked_link_client) { create(:client, company: unlocked_link_company) }
  let(:unlocked_link_admin) { create(:user, current_workspace_id: unlocked_link_company.id) }
  let(:unlocked_link_project) { create(:project, client: unlocked_link_client, billable: true) }

  before do
    create(:employment, company: unlocked_link_company, user: unlocked_link_admin)
    unlocked_link_admin.add_role :admin, unlocked_link_company
    sign_in unlocked_link_admin
  end

  # "a second kept invoice on the same entry fails with \"entry is on another invoice\""
  # Scenario: the sent invoice comes first. It holds its entry with no lock and no holding row
  # (the legacy "unlocked link"), so a check that reads only locks or holdings would let the draft take it.
  it "refuses a draft update that adds an entry still on a sent invoice whose entries were never locked" do
    entry = create(:timesheet_entry, user: unlocked_link_admin, project: unlocked_link_project,
      bill_status: :unbilled, locked: false, work_date: Date.current, duration: 60)
    sent = create(:invoice, company: unlocked_link_company, client: unlocked_link_client, status: :sent)
    create(:invoice_line_item, invoice: sent, timesheet_entry: entry, rate: 100, quantity: 60)
    expect(entry.reload.locked).to be(false)
    expect(InvoiceEntryHolding.where(company_id: unlocked_link_company.id, invoice_id: sent.id)).to be_empty
    draft = create(:invoice, company: unlocked_link_company, client: unlocked_link_client)

    expect do
      send_request :patch, api_v1_invoice_path(draft), params: {
        invoice: {
          client_id: unlocked_link_client.id,
          invoice_number: draft.invoice_number,
          issue_date: draft.issue_date.iso8601,
          due_date: draft.due_date.iso8601,
          status: "draft",
          currency: unlocked_link_company.base_currency,
          invoice_line_items_attributes: [
            { name: "Work", description: "Work", date: Date.current.iso8601, rate: 100, quantity: 60,
              timesheet_entry_id: entry.id }
          ]
        }
      }, headers: auth_headers(unlocked_link_admin)
    end.not_to change(InvoiceLineItem, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("entry is on another invoice")
    expect(draft.reload.invoice_line_items).to be_empty
    expect(entry.reload.locked).to be(false)
    expect(sent.reload.invoice_line_items.pluck(:timesheet_entry_id)).to eq([entry.id])
  end
end

# Generated by Descant: acceptance tests below.
RSpec.describe "Api::V1::Invoices#update timesheet entry company scope", type: :request do
  # Missing ids, other companies' ids and entries with no company must all get the same 422 "not found",
  # so no response reveals that another company's entry exists.
  let(:scope_company) { create(:company, base_currency: "USD") }
  let(:scope_client) { create(:client, company: scope_company) }
  let(:scope_admin) { create(:user, current_workspace_id: scope_company.id) }
  let(:scope_project) { create(:project, client: scope_client, billable: true) }
  let(:other_company) { create(:company) }
  let(:other_user) { create(:user, current_workspace_id: other_company.id) }
  let(:other_project) { create(:project, client: create(:client, company: other_company), billable: true) }

  before do
    create(:employment, company: scope_company, user: scope_admin)
    scope_admin.add_role :admin, scope_company
    create(:employment, company: other_company, user: other_user)
    sign_in scope_admin
  end

  let!(:own_entry) do
    create(:timesheet_entry, user: scope_admin, project: scope_project, bill_status: :unbilled, locked: false,
      work_date: Date.current, duration: 60)
  end
  let!(:foreign_entry) do
    create(:timesheet_entry, user: other_user, project: other_project, bill_status: :unbilled, locked: false,
      work_date: Date.current, duration: 60)
  end
  let!(:null_company_entry) do
    entry = create(:timesheet_entry, user: scope_admin, project: scope_project, bill_status: :unbilled, locked: false,
      work_date: Date.current, duration: 60)
    # update_column skips the save callback that would refill company_id from the project.
    entry.update_column(:company_id, nil)
    entry
  end
  let(:missing_id) { TimesheetEntry.maximum(:id).to_i + 1_000 }

  let!(:scope_invoice) do
    create(:invoice, company: scope_company, client: scope_client, invoice_number: "INV-COMPANY-SCOPE-UP-001")
  end
  # A line whose entries are linked through join rows, starting with the own entry.
  let!(:aggregate_line) do
    line = create(:invoice_line_item, invoice: scope_invoice, timesheet_entry: nil, name: "Aggregate",
      description: "Aggregate", rate: 100, quantity: 60)
    create(:invoice_line_item_time_entry, invoice_line_item: line, timesheet_entry: own_entry)
    line
  end
  # A line with no direct entry, so a refused direct id must leave it at nil.
  let!(:manual_line) do
    create(:invoice_line_item, invoice: scope_invoice, timesheet_entry: nil, name: "Manual",
      description: "Manual", rate: 100, quantity: 60)
  end

  # Every example compares against this seeded state. If the setup drifts, the examples fail here
  # instead of passing on two trivially equal responses.
  before do
    expect(foreign_entry.reload.company_id).to eq(other_company.id)
    expect(null_company_entry.reload.company_id).to be_nil
    expect(TimesheetEntry.exists?(missing_id)).to be(false)
    expect([foreign_entry.reload.locked, null_company_entry.reload.locked]).to eq([false, false])
    expect(aggregate_line.reload.linked_timesheet_entry_ids).to eq([own_entry.id])
    expect(manual_line.reload.timesheet_entry_id).to be_nil
  end

  # Sends every scalar attribute of the line unchanged, so only the entry reference differs.
  # entry_ref is { timesheet_entry_id: } or { linked_timesheet_entry_ids: }.
  def patch_company_scope_line(line, entry_ref)
    send_request :patch, api_v1_invoice_path(scope_invoice), params: {
      invoice: {
        client_id: scope_client.id,
        invoice_number: scope_invoice.invoice_number,
        issue_date: scope_invoice.issue_date.iso8601,
        due_date: scope_invoice.due_date.iso8601,
        status: "draft",
        currency: scope_company.base_currency,
        invoice_line_items_attributes: [
          { id: line.id, name: line.name, description: line.description, date: line.date.iso8601,
            rate: line.rate, quantity: line.quantity }.merge(entry_ref)
        ]
      }
    }, headers: auth_headers(scope_admin)
    [response.status, response.body]
  end

  it "refuses a link-only update naming a foreign entry exactly like a missing id and keeps the old links" do
    join_row_ids = InvoiceLineItemTimeEntry.where(invoice_line_item_id: aggregate_line.id).pluck(:id)

    # Each refused call is checked against the seeded state on its own, so a write by the first
    # cannot hide behind the second.
    results = [[foreign_entry.id], [missing_id]].map do |entry_ids|
      result = nil
      expect do
        result = patch_company_scope_line(aggregate_line, linked_timesheet_entry_ids: entry_ids)
      end.to not_change(Invoice, :count)
        .and not_change(InvoiceLineItem, :count)
        .and not_change(InvoiceLineItemTimeEntry, :count)
      expect(aggregate_line.reload.linked_timesheet_entry_ids).to eq([own_entry.id])
      expect(InvoiceLineItemTimeEntry.where(invoice_line_item_id: aggregate_line.id).pluck(:id)).to eq(join_row_ids)
      expect(foreign_entry.reload.locked).to be(false)
      result
    end
    foreign_result, missing_result = results

    expect(foreign_result.first).to eq(422)
    expect(foreign_result).to eq(missing_result)
    expect(JSON.parse(foreign_result.last)["errors"]).to include("not found")
    expect(foreign_result.last).not_to include(foreign_entry.id.to_s)
  end

  it "refuses a foreign direct timesheet_entry_id exactly like a missing one and leaves the line without an entry" do
    results = [foreign_entry.id, missing_id].map do |entry_id|
      result = nil
      expect do
        result = patch_company_scope_line(manual_line, timesheet_entry_id: entry_id)
      end.to not_change(Invoice, :count)
        .and not_change(InvoiceLineItem, :count)
        .and not_change(InvoiceLineItemTimeEntry, :count)
      expect(manual_line.reload.timesheet_entry_id).to be_nil
      expect(foreign_entry.reload.locked).to be(false)
      result
    end
    foreign_result, missing_result = results

    expect(foreign_result.first).to eq(422)
    expect(foreign_result).to eq(missing_result)
    expect(JSON.parse(foreign_result.last)["errors"]).to include("not found")
    expect(foreign_result.last).not_to include(foreign_entry.id.to_s)
  end

  it "refuses a NULL-company entry, direct or linked, exactly like a missing id and leaves it unlocked" do
    direct_result = nil
    linked_result = nil
    expect do
      direct_result = patch_company_scope_line(manual_line, timesheet_entry_id: null_company_entry.id)
      linked_result = patch_company_scope_line(aggregate_line, linked_timesheet_entry_ids: [null_company_entry.id])
    end.to not_change(Invoice, :count)
      .and not_change(InvoiceLineItem, :count)
      .and not_change(InvoiceLineItemTimeEntry, :count)

    expect(direct_result.first).to eq(422)
    expect(direct_result).to eq(patch_company_scope_line(manual_line, timesheet_entry_id: missing_id))
    expect(linked_result.first).to eq(422)
    expect(linked_result).to eq(patch_company_scope_line(aggregate_line, linked_timesheet_entry_ids: [missing_id]))
    expect(JSON.parse(direct_result.last)["errors"]).to include("not found")
    expect(manual_line.reload.timesheet_entry_id).to be_nil
    expect(aggregate_line.reload.linked_timesheet_entry_ids).to eq([own_entry.id])
    expect(null_company_entry.reload.locked).to be(false)
  end

  it "applies a link-only replacement that adds no join rows when repeated, then a link-only clear" do
    new_entries = create_list(:timesheet_entry, 2, user: scope_admin, project: scope_project, bill_status: :unbilled,
      locked: false, work_date: Date.current, duration: 60)

    2.times do
      status, _body = patch_company_scope_line(aggregate_line, linked_timesheet_entry_ids: new_entries.map(&:id))
      expect(status).to eq(200)
      expect(InvoiceLineItemTimeEntry.where(invoice_line_item_id: aggregate_line.id).pluck(:timesheet_entry_id))
        .to match_array(new_entries.map(&:id))
    end

    # A form-encoded empty list arrives as one blank value, and it must clear the links rather than be ignored.
    status, _body = patch_company_scope_line(aggregate_line, linked_timesheet_entry_ids: [""])
    expect(status).to eq(200)
    expect(aggregate_line.reload.linked_timesheet_entry_ids).to eq([])
  end
end
