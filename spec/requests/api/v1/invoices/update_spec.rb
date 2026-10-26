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

# Generated by Descant: acceptance tests below.
RSpec.describe "Api::V1::Invoices#update with linked entry ids from another company", type: :request do
  it "refuses a link-only update naming another company's entry with the same 422 body as a nonexistent id and keeps the old links" do
    company = create(:company)
    client = create(:client, company:)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role :admin, company
    sign_in user

    project = create(:project, client:, billable: true)
    own_entry = create(:timesheet_entry, user:, project:, bill_status: "unbilled")
    invoice = create(:invoice, company:, client:, invoice_number: "INV-LINK-SCOPE-001")
    line_item = create(:invoice_line_item, invoice:, timesheet_entry: nil, name: "Aggregate", rate: 100, quantity: 60)
    create(:invoice_line_item_time_entry, invoice_line_item: line_item, timesheet_entry: own_entry)

    other_company = create(:company)
    other_project = create(:project, client: create(:client, company: other_company), billable: true)
    other_user = create(:user, current_workspace_id: other_company.id)
    foreign_entry = create(:timesheet_entry, user: other_user, project: other_project, bill_status: "unbilled")
    nonexistent_id = TimesheetEntry.maximum(:id).to_i + 1_000

    patch_links = lambda do |ids|
      send_request :patch, api_v1_invoice_path(invoice), params: {
        invoice: {
          client_id: client.id,
          invoice_number: "INV-LINK-SCOPE-001",
          issue_date: invoice.issue_date.iso8601,
          due_date: invoice.due_date.iso8601,
          status: "draft",
          currency: company.base_currency,
          invoice_line_items_attributes: [
            {
              id: line_item.id,
              name: line_item.name,
              description: line_item.description,
              date: line_item.date.iso8601,
              rate: line_item.rate,
              quantity: line_item.quantity,
              linked_timesheet_entry_ids: ids
            }
          ]
        }
      }, headers: auth_headers(user)
      [response.status, response.body]
    end

    foreign_result = patch_links.call([foreign_entry.id])
    missing_result = patch_links.call([nonexistent_id])

    # "A missing entry id and a foreign entry id give the same response, so no response reveals another company's entries"
    expect(foreign_result.first).to eq(422)
    expect(foreign_result).to eq(missing_result)
    expect(foreign_result.last).to include("not found")
    expect(foreign_result.last).not_to include(foreign_entry.id.to_s)
    expect(line_item.reload.linked_timesheet_entries.ids).to eq([own_entry.id])
  end
end

RSpec.describe "Api::V1::Invoices#update with a direct entry id from another company", type: :request do
  it "refuses an update setting a direct timesheet entry id from another company with the same 422 body as a nonexistent id" do
    company = create(:company)
    client = create(:client, company:)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role :admin, company
    sign_in user

    invoice = create(:invoice, company:, client:, invoice_number: "INV-DIRECT-SCOPE-001")
    line_item = create(:invoice_line_item, invoice:, timesheet_entry: nil, name: "Manual", rate: 100, quantity: 60)

    other_company = create(:company)
    other_project = create(:project, client: create(:client, company: other_company), billable: true)
    other_user = create(:user, current_workspace_id: other_company.id)
    foreign_entry = create(:timesheet_entry, user: other_user, project: other_project, bill_status: "unbilled")
    nonexistent_id = TimesheetEntry.maximum(:id).to_i + 1_000

    patch_direct = lambda do |entry_id|
      send_request :patch, api_v1_invoice_path(invoice), params: {
        invoice: {
          client_id: client.id,
          invoice_number: "INV-DIRECT-SCOPE-001",
          issue_date: invoice.issue_date.iso8601,
          due_date: invoice.due_date.iso8601,
          status: "draft",
          currency: company.base_currency,
          invoice_line_items_attributes: [
            {
              id: line_item.id,
              name: line_item.name,
              date: line_item.date.iso8601,
              rate: line_item.rate,
              quantity: line_item.quantity,
              timesheet_entry_id: entry_id
            }
          ]
        }
      }, headers: auth_headers(user)
      [response.status, response.body]
    end

    foreign_result = patch_direct.call(foreign_entry.id)
    missing_result = patch_direct.call(nonexistent_id)

    # "An entry id from another company gives not_found"
    expect(foreign_result.first).to eq(422)
    expect(foreign_result.last).to include("not found")
    # "A missing entry id and a foreign entry id give the same response, so no response reveals another company's entries"
    expect(foreign_result).to eq(missing_result)
    expect(line_item.reload.timesheet_entry_id).to be_nil
    expect(foreign_entry.reload.locked).to be_falsey
  end
end

RSpec.describe "Api::V1::Invoices#update replacing only linked entries", type: :request do
  it "a link-only update of an existing line persists the replacement and repeating it adds no join rows" do
    company = create(:company)
    client = create(:client, company:)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role :admin, company
    sign_in user

    project = create(:project, client:, billable: true)
    old_entry, *new_entries = create_list(
      :timesheet_entry, 3, user:, project:, bill_status: :unbilled, locked: false, work_date: Date.current
    )
    invoice = create(:invoice, company:, client:, invoice_number: "INV-LINK-REPLACE-001")
    line_item = create(:invoice_line_item, invoice:, timesheet_entry: nil, name: "Aggregate", rate: 100, quantity: 60)
    create(:invoice_line_item_time_entry, invoice_line_item: line_item, timesheet_entry: old_entry)
    expect(line_item.reload.linked_timesheet_entry_ids).to eq([old_entry.id])

    # Every scalar attribute is sent unchanged, so only the linked ids differ.
    patch_params = {
      invoice: {
        client_id: client.id,
        invoice_number: invoice.invoice_number,
        issue_date: invoice.issue_date.iso8601,
        due_date: invoice.due_date.iso8601,
        status: "draft",
        currency: company.base_currency,
        invoice_line_items_attributes: [
          {
            id: line_item.id,
            name: line_item.name,
            description: line_item.description,
            date: line_item.date.iso8601,
            rate: line_item.rate,
            quantity: line_item.quantity,
            linked_timesheet_entry_ids: new_entries.map(&:id)
          }
        ]
      }
    }

    2.times do
      send_request :patch, api_v1_invoice_path(invoice), params: patch_params, headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(InvoiceLineItemTimeEntry.where(invoice_line_item_id: line_item.id).pluck(:timesheet_entry_id))
        .to match_array(new_entries.map(&:id))
    end
  end
end

RSpec.describe "Api::V1::Invoices#update linking another company's entry", type: :request do
  it "a link-only update naming another company's entry is refused and leaves the stored links and that entry unchanged" do
    company = create(:company)
    client = create(:client, company:)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role :admin, company
    sign_in user

    project = create(:project, client:, billable: true)
    own_entry = create(:timesheet_entry, user:, project:, bill_status: :unbilled, work_date: Date.current)
    invoice = create(:invoice, company:, client:, invoice_number: "INV-LINK-FOREIGN-001")
    line_item = create(:invoice_line_item, invoice:, timesheet_entry: nil, name: "Aggregate", rate: 100, quantity: 60)
    create(:invoice_line_item_time_entry, invoice_line_item: line_item, timesheet_entry: own_entry)

    other_company = create(:company)
    other_project = create(:project, client: create(:client, company: other_company), billable: true)
    other_user = create(:user, current_workspace_id: other_company.id)
    create(:employment, company: other_company, user: other_user)
    foreign_entry = create(
      :timesheet_entry, user: other_user, project: other_project, bill_status: :unbilled, locked: false, work_date: Date.current
    )
    expect(foreign_entry.reload.locked).to be(false)
    expect(line_item.reload.linked_timesheet_entry_ids).to eq([own_entry.id])

    patch_body = lambda do |linked_ids|
      {
        invoice: {
          client_id: client.id,
          invoice_number: invoice.invoice_number,
          issue_date: invoice.issue_date.iso8601,
          due_date: invoice.due_date.iso8601,
          status: "draft",
          currency: company.base_currency,
          invoice_line_items_attributes: [
            {
              id: line_item.id,
              name: line_item.name,
              description: line_item.description,
              date: line_item.date.iso8601,
              rate: line_item.rate,
              quantity: line_item.quantity,
              linked_timesheet_entry_ids: linked_ids
            }
          ]
        }
      }
    end

    # "A missing id and a foreign id must both give the same `not_found` error, rendered through the existing 422 path."
    send_request :patch, api_v1_invoice_path(invoice), params: patch_body.call([foreign_entry.id]), headers: auth_headers(user)
    foreign_status = response.status
    foreign_body = response.body

    missing_id = TimesheetEntry.maximum(:id).to_i + 1_000
    send_request :patch, api_v1_invoice_path(invoice), params: patch_body.call([missing_id]), headers: auth_headers(user)

    expect(foreign_status).to eq(422)
    expect([response.status, response.body]).to eq([foreign_status, foreign_body])
    expect(foreign_body).to include("not found")
    expect(InvoiceLineItemTimeEntry.where(invoice_line_item_id: line_item.id).pluck(:timesheet_entry_id))
      .to eq([own_entry.id])
    expect(foreign_entry.reload.locked).to be(false)
  end
end

RSpec.describe "Api::V1::Invoices#update of linked entries outside the company", type: :request do
  it "refuses a link-only update of an existing line with a foreign or nonexistent id identically and keeps its links" do
    company = create(:company)
    client = create(:client, company:)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role :admin, company
    sign_in user
    project = create(:project, client:, billable: true)
    own_entry = create(:timesheet_entry, user:, project:, bill_status: "unbilled", work_date: Date.current)
    invoice = create(:invoice, company:, client:, invoice_number: "INV-LINK-FOREIGN-001")
    line = create(:invoice_line_item, invoice:, timesheet_entry: nil, name: "Aggregate", description: "Aggregate",
      rate: 100, quantity: 60)
    create(:invoice_line_item_time_entry, invoice_line_item: line, timesheet_entry: own_entry)

    other_company = create(:company)
    other_project = create(:project, client: create(:client, company: other_company), billable: true)
    other_user = create(:user, current_workspace_id: other_company.id)
    create(:employment, company: other_company, user: other_user)
    foreign_entry = create(:timesheet_entry, user: other_user, project: other_project, bill_status: "unbilled",
      locked: false)
    missing_id = TimesheetEntry.maximum(:id).to_i + 1_000

    # Every scalar attribute is sent unchanged, so only the linked ids differ.
    params_for = lambda do |entry_id|
      {
        invoice: {
          client_id: client.id,
          invoice_number: invoice.invoice_number,
          issue_date: invoice.issue_date.iso8601,
          due_date: invoice.due_date.iso8601,
          status: "draft",
          currency: company.base_currency,
          invoice_line_items_attributes: [
            { id: line.id, name: line.name, description: line.description, date: line.date.iso8601,
              rate: line.rate, quantity: line.quantity, linked_timesheet_entry_ids: [entry_id] }
          ]
        }
      }
    end

    send_request :patch, api_v1_invoice_path(invoice), params: params_for.call(foreign_entry.id), headers: auth_headers(user)
    foreign_result = [response.status, response.body]
    expect(line.reload.linked_timesheet_entry_ids).to eq([own_entry.id])
    expect(foreign_entry.reload.locked).to be(false)

    send_request :patch, api_v1_invoice_path(invoice), params: params_for.call(missing_id), headers: auth_headers(user)

    # "A missing entry id and a foreign entry id give the same response, so no response reveals another company's entries"
    expect(foreign_result.first).to eq(422)
    expect(JSON.parse(foreign_result.last)["errors"]).to include("not found")
    expect([response.status, response.body]).to eq(foreign_result)
    expect(line.reload.linked_timesheet_entry_ids).to eq([own_entry.id])
  end
end

RSpec.describe "Api::V1::Invoices#update of linked entries within the company", type: :request do
  it "applies a link-only update of an existing line that replaces and then clears its company entries" do
    company = create(:company)
    client = create(:client, company:)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role :admin, company
    sign_in user
    project = create(:project, client:, billable: true)
    first_entry, second_entry = create_list(:timesheet_entry, 2, user:, project:, bill_status: "unbilled",
      work_date: Date.current)
    invoice = create(:invoice, company:, client:, invoice_number: "INV-LINK-REPLACE-001")
    line = create(:invoice_line_item, invoice:, timesheet_entry: nil, name: "Aggregate", description: "Aggregate",
      rate: 100, quantity: 60)
    create(:invoice_line_item_time_entry, invoice_line_item: line, timesheet_entry: first_entry)

    params_for = lambda do |linked_ids|
      {
        invoice: {
          client_id: client.id,
          invoice_number: invoice.invoice_number,
          issue_date: invoice.issue_date.iso8601,
          due_date: invoice.due_date.iso8601,
          status: "draft",
          currency: company.base_currency,
          invoice_line_items_attributes: [
            { id: line.id, name: line.name, description: line.description, date: line.date.iso8601,
              rate: line.rate, quantity: line.quantity, linked_timesheet_entry_ids: linked_ids }
          ]
        }
      }
    end

    send_request :patch, api_v1_invoice_path(invoice), params: params_for.call([second_entry.id]), headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    expect(line.reload.linked_timesheet_entry_ids).to eq([second_entry.id])

    # A form-encoded empty list arrives as one blank value.
    send_request :patch, api_v1_invoice_path(invoice), params: params_for.call([""]), headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    expect(line.reload.linked_timesheet_entry_ids).to eq([])
  end
end

RSpec.describe "Api::V1::Invoices#update of a direct entry outside the company", type: :request do
  it "refuses an update of an existing line to a foreign or nonexistent timesheet_entry_id identically" do
    company = create(:company)
    client = create(:client, company:)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role :admin, company
    sign_in user
    invoice = create(:invoice, company:, client:, invoice_number: "INV-DIRECT-FOREIGN-001")
    line = create(:invoice_line_item, invoice:, timesheet_entry: nil, name: "Manual", description: "Manual",
      rate: 100, quantity: 60)

    other_company = create(:company)
    other_project = create(:project, client: create(:client, company: other_company), billable: true)
    other_user = create(:user, current_workspace_id: other_company.id)
    create(:employment, company: other_company, user: other_user)
    foreign_entry = create(:timesheet_entry, user: other_user, project: other_project, bill_status: "unbilled",
      locked: false)
    missing_id = TimesheetEntry.maximum(:id).to_i + 1_000

    params_for = lambda do |entry_id|
      {
        invoice: {
          client_id: client.id,
          invoice_number: invoice.invoice_number,
          issue_date: invoice.issue_date.iso8601,
          due_date: invoice.due_date.iso8601,
          status: "draft",
          currency: company.base_currency,
          invoice_line_items_attributes: [
            { id: line.id, name: line.name, description: line.description, date: line.date.iso8601,
              rate: line.rate, quantity: line.quantity, timesheet_entry_id: entry_id }
          ]
        }
      }
    end

    send_request :patch, api_v1_invoice_path(invoice), params: params_for.call(foreign_entry.id), headers: auth_headers(user)
    foreign_result = [response.status, response.body]
    expect(line.reload.timesheet_entry_id).to be_nil
    expect(foreign_entry.reload.locked).to be(false)

    send_request :patch, api_v1_invoice_path(invoice), params: params_for.call(missing_id), headers: auth_headers(user)

    # "An entry id from another company gives not_found"
    expect(foreign_result.first).to eq(422)
    expect(JSON.parse(foreign_result.last)["errors"]).to include("not found")
    expect([response.status, response.body]).to eq(foreign_result)
  end
end

RSpec.describe "Api::V1::Invoices#update with link-only changes", type: :request do
  it "refuses a link-only change to an existing line naming a foreign entry with the same 422 as a nonexistent id" do
    company = create(:company)
    client = create(:client, company:)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role :admin, company
    sign_in user
    project = create(:project, client:, billable: true)
    own_entry = create(:timesheet_entry, user:, project:, bill_status: :unbilled, work_date: Date.current)
    invoice = create(:invoice, company:, client:, invoice_number: "INV-LINK-ONLY-001")
    line_item = create(:invoice_line_item, invoice:, timesheet_entry: nil, name: "Aggregate", description: "Work", rate: 100, quantity: 60)
    create(:invoice_line_item_time_entry, invoice_line_item: line_item, timesheet_entry: own_entry)

    other_company = create(:company)
    other_user = create(:user, current_workspace_id: other_company.id)
    create(:employment, company: other_company, user: other_user)
    other_project = create(:project, client: create(:client, company: other_company), billable: true)
    foreign_entry = create(:timesheet_entry, user: other_user, project: other_project, bill_status: :unbilled, locked: false, work_date: Date.current)
    missing_id = TimesheetEntry.maximum(:id).to_i + 1_000

    # Every scalar attribute is sent unchanged, so only the pending linked ids
    # can make nested autosave validate this line.
    patch_links = lambda do |linked_ids|
      send_request :patch, api_v1_invoice_path(invoice), params: {
        invoice: {
          client_id: client.id,
          invoice_number: "INV-LINK-ONLY-001",
          issue_date: invoice.issue_date.iso8601,
          due_date: invoice.due_date.iso8601,
          status: "draft",
          currency: company.base_currency,
          invoice_line_items_attributes: [
            {
              id: line_item.id,
              name: line_item.name,
              description: line_item.description,
              date: line_item.date.iso8601,
              rate: line_item.rate,
              quantity: line_item.quantity,
              linked_timesheet_entry_ids: linked_ids
            }
          ]
        }
      }, headers: auth_headers(user)
      [response.status, response.body]
    end

    # "A missing id and a foreign id must both give the same `not_found` error, rendered through the existing 422 path."
    foreign_result = patch_links.call([foreign_entry.id])
    missing_result = patch_links.call([missing_id])

    expect(foreign_result.first).to eq(422)
    expect(foreign_result).to eq(missing_result)
    expect(foreign_result.last).to include("not found")
    expect(line_item.reload.linked_timesheet_entry_ids).to eq([own_entry.id])
    expect(foreign_entry.reload.locked).to be(false)
  end
end

RSpec.describe "Api::V1::Invoices#update applying link-only changes", type: :request do
  it "applies a link-only replacement and a link-only clear on an existing line instead of silently dropping them" do
    company = create(:company)
    client = create(:client, company:)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role :admin, company
    sign_in user
    project = create(:project, client:, billable: true)
    first_entry, second_entry = create_list(:timesheet_entry, 2, user:, project:, bill_status: :unbilled, work_date: Date.current)
    invoice = create(:invoice, company:, client:, invoice_number: "INV-LINK-SWAP-001")
    line_item = create(:invoice_line_item, invoice:, timesheet_entry: nil, name: "Aggregate", description: "Work", rate: 100, quantity: 60)
    create(:invoice_line_item_time_entry, invoice_line_item: line_item, timesheet_entry: first_entry)

    patch_links = lambda do |linked_ids|
      send_request :patch, api_v1_invoice_path(invoice), params: {
        invoice: {
          client_id: client.id,
          invoice_number: "INV-LINK-SWAP-001",
          issue_date: invoice.issue_date.iso8601,
          due_date: invoice.due_date.iso8601,
          status: "draft",
          currency: company.base_currency,
          invoice_line_items_attributes: [
            {
              id: line_item.id,
              name: line_item.name,
              description: line_item.description,
              date: line_item.date.iso8601,
              rate: line_item.rate,
              quantity: line_item.quantity,
              linked_timesheet_entry_ids: linked_ids
            }
          ]
        }
      }, headers: auth_headers(user)
      response.status
    end

    # "Resolve `timesheet_entry_id` and linked entry ids only within `invoice.company_id`"
    expect(patch_links.call([second_entry.id])).to eq(200)
    expect(line_item.reload.linked_timesheet_entry_ids).to eq([second_entry.id])

    # An empty list still clears the links rather than being ignored.
    expect(patch_links.call([""])).to eq(200)
    expect(line_item.reload.linked_timesheet_entry_ids).to eq([])
  end
end
