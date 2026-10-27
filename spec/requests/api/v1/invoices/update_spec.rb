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

RSpec.describe "Api::V1::Invoices#update under the Timekeeping owner", type: :request do
  let(:remote_company) { create(:company) }
  let(:remote_client) { create(:client, company: remote_company) }
  let(:remote_project) { create(:project, client: remote_client, billable: true) }
  let(:remote_user) { create(:user, current_workspace_id: remote_company.id) }
  let(:remote_fake) { TimekeepingContract::FakeTimekeeping.new }

  before do
    create(:employment, company: remote_company, user: remote_user)
    remote_user.add_role :admin, remote_company
    sign_in remote_user
  end

  # "the fake's request log shows exactly one prepare for a nested `PATCH /api/v1/invoices/:id` with `invoice_line_items_attributes`."
  it "a nested draft update under the Timekeeping owner sends exactly one prepare to the fake and commits both entries" do
    TimekeepingOwnership.current.update!(owner: "timekeeping", handoff_step: nil)
    remote_fake.generation = TimekeepingOwnership.current.generation
    credential = remote_fake.add_service(company_id: remote_company.id, name: "monolith-invoices",
                                         operations: %w[prepare commit abort mark_billed])
    reservation_client = Timekeeping::ReservationClient.new(
      http: TimekeepingContract::FakeClient.new(timekeeping: remote_fake, relay: nil),
      credential: ->(company_id:, operation:) { credential }
    )
    allow(Timekeeping::ReservationClient).to receive(:build).and_return(reservation_client)
    invoice = create(:invoice, company: remote_company, client: remote_client, invoice_number: "INV-REMOTE-1")
    entries = Array.new(2) do
      create(:timesheet_entry, user: remote_user, project: remote_project, bill_status: "unbilled")
    end
    entries.each do |entry|
      remote_fake.add_entry(company_id: remote_company.id, user_id: remote_user.id, project_id: remote_project.id,
                            id: entry.id)
    end
    line_items = entries.map do |entry|
      { name: "Entry", description: "line", date: Date.current.iso8601, rate: 100, quantity: 60, timesheet_entry_id: entry.id }
    end

    send_request :patch, api_v1_invoice_path(invoice), params: {
      invoice: {
        client_id: remote_client.id, invoice_number: "INV-REMOTE-1",
        issue_date: invoice.issue_date.iso8601, due_date: invoice.due_date.iso8601,
        status: "draft", currency: remote_company.base_currency, invoice_line_items_attributes: line_items
      }
    }, headers: auth_headers(remote_user)

    expect(response).to have_http_status(:ok)
    prepare_path = "/v1/companies/#{remote_company.id}/reservations/prepare"
    expect(remote_fake.requests.count { |call| call[:path] == prepare_path }).to eq(1)
    expect(entries.map { |entry| remote_fake.reservations_for(entry.id) })
      .to eq([[{ "invoice_id" => invoice.id, "state" => "committed" }]] * 2)
  end
end
