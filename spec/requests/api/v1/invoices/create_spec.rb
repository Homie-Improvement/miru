# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Invoices#create", type: :request do
  let_it_be(:company) { create(:company, :with_logo, base_currency: "USD") }
  let_it_be(:client) { create(:client, company:) }
  let(:user) { create(:user, email: "invoice-create-admin@example.com", current_workspace_id: company.id) }

  context "when user is an admin" do
    before do
      create(:employment, company:, user:)
      user.add_role :admin, company
      sign_in user
    end

    describe "invoice creation" do
      let(:invoice) {
        attributes_for(
          :invoice,
          invoice_number: "SAI-C1-03",
          client:,
          client_id: client.id,
          invoice_line_item: {
            name: "Test",
            description: "test description",
            data: Faker::Date.in_date_period,
            rate: 12.4,
            quantity: 34.54
          }
        )
      }

      it "creates invoice successfully" do
        send_request :post, api_v1_invoices_path(invoice:), headers: auth_headers(user)
        expect(response).to have_http_status(:ok)
        expected_attrs =
          ["amount", "amountDue", "amountPaid", "baseCurrencyAmount", "client", "currency", "discount", "dueDate",
           "company", "id", "invoiceLineItems", "invoiceNumber", "invoiceTaxes", "issueDate",
           "outstandingAmount", "reference", "status", "stripeEnabled", "tax"]
        expect(json_response.keys.sort).to match_array(expected_attrs)
        # Verify searchable immediately without reindex
        assert_equal ["SAI-C1-03"], Invoice.search("SAI-C1-03").map(&:invoice_number)
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

        send_request :post, api_v1_invoices_path(
          invoice: {
            client_id: client.id,
            invoice_number: "INV-COMPANY-001",
            issue_date: Date.current.iso8601,
            due_date: 30.days.from_now.to_date.iso8601,
            status: "draft",
            currency: company.base_currency,
            invoice_line_items_attributes: [
              {
                name: "Discovery",
                description: "Analysis block",
                date: Date.current.iso8601,
                rate: 100,
                quantity: 120
              }
            ]
          }), headers: auth_headers(user)

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

      it "creates invoice line items with date and timesheet entry associations" do
        project = create(:project, client:)
        timesheet_entry = create(
          :timesheet_entry,
          user:,
          project:,
          work_date: Date.current,
          duration: 120
        )

        send_request :post, api_v1_invoices_path(
          invoice: {
            client_id: client.id,
            invoice_number: "INV-TIMESHEET-001",
            issue_date: Date.current.iso8601,
            due_date: 30.days.from_now.to_date.iso8601,
            status: "draft",
            currency: company.base_currency,
            invoice_line_items_attributes: [
              {
                name: "Timesheet entry",
                description: "Linked entry",
                date: timesheet_entry.work_date.iso8601,
                rate: 100,
                quantity: 120,
                timesheet_entry_id: timesheet_entry.id
              }
            ]
          }), headers: auth_headers(user)

        expect(response).to have_http_status(:ok)

        invoice = Invoice.find_by!(invoice_number: "INV-TIMESHEET-001")
        line_item = invoice.invoice_line_items.last

        expect(line_item.date).to eq(timesheet_entry.work_date)
        expect(line_item.timesheet_entry_id).to eq(timesheet_entry.id)
      end

      it "accepts zero line-item rates and rejects negative rates" do
        invoice_params = lambda do |invoice_number, rate|
          {
            client_id: client.id,
            invoice_number:,
            issue_date: Date.current.iso8601,
            due_date: 30.days.from_now.to_date.iso8601,
            status: "draft",
            currency: company.base_currency,
            invoice_line_items_attributes: [
              {
                name: "Trial period",
                description: "Complimentary trial work",
                date: Date.current.iso8601,
                rate:,
                quantity: 120
              }
            ]
          }
        end

        send_request :post, api_v1_invoices_path(
          invoice: invoice_params.call("INV-ZERO-RATE-001", 0)
        ), headers: auth_headers(user)

        expect(response).to have_http_status(:ok)
        expect(Invoice.find_by!(invoice_number: "INV-ZERO-RATE-001").invoice_line_items.sole.rate).to eq(0)

        expect do
          send_request :post, api_v1_invoices_path(
            invoice: invoice_params.call("INV-NEGATIVE-RATE-001", -1)
          ), headers: auth_headers(user)
        end.not_to change(Invoice, :count)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("greater than or equal to 0")
      end

      it "creates aggregate invoice line items linked to multiple timesheet entries" do
        project = create(:project, client:, name: "Platform Build", billable: true)
        entries = create_list(
          :timesheet_entry,
          2,
          user:,
          project:,
          bill_status: :unbilled,
          locked: false,
          work_date: Date.current
        )

        send_request :post, api_v1_invoices_path(
          invoice: {
            client_id: client.id,
            invoice_number: "INV-AGGREGATE-001",
            issue_date: Date.current.iso8601,
            due_date: 30.days.from_now.to_date.iso8601,
            status: "draft",
            currency: company.base_currency,
            invoice_line_items_attributes: [
              {
                name: project.name,
                description: "Aggregated project work",
                date: Date.current.iso8601,
                rate: 100,
                quantity: entries.sum(&:duration),
                linked_timesheet_entry_ids: entries.map(&:id)
              }
            ]
          }), headers: auth_headers(user)

        expect(response).to have_http_status(:ok)

        invoice = Invoice.find_by!(invoice_number: "INV-AGGREGATE-001")
        line_item = invoice.invoice_line_items.last

        expect(line_item.name).to eq("Platform Build")
        expect(line_item.timesheet_entry_id).to be_nil
        expect(line_item.linked_timesheet_entry_ids).to match_array(entries.map(&:id))
        expect(entries.map { |entry| entry.reload.locked }).to all(be(true))
      end

      it "calculates invoice totals from line items, discount, and tax" do
        send_request :post, api_v1_invoices_path(
          invoice: {
            client_id: client.id,
            invoice_number: "INV-TOTALS-001",
            issue_date: Date.current.iso8601,
            due_date: 30.days.from_now.to_date.iso8601,
            status: "draft",
            currency: company.base_currency,
            discount: 25,
            tax: 10,
            invoice_line_items_attributes: [
              {
                name: "Discovery",
                description: "Analysis block",
                date: Date.current.iso8601,
                rate: 100,
                quantity: 120
              },
              {
                name: "QA",
                description: "Validation block",
                date: Date.current.iso8601,
                rate: 90,
                quantity: 60
              }
            ]
          }), headers: auth_headers(user)

        expect(response).to have_http_status(:ok)

        invoice = Invoice.find_by!(invoice_number: "INV-TOTALS-001")
        expect(invoice.amount.to_f).to eq(275.0)
        expect(invoice.amount_due.to_f).to eq(275.0)
        expect(json_response["amount"].to_f).to eq(275.0)
        expect(json_response["amountDue"].to_f).to eq(275.0)
      end

      it "calculates invoice totals from configured invoice taxes" do
        cgst = create(:tax_configuration, company:, name: "CGST", calculation_method: "percentage", value: 9)
        sgst = create(:tax_configuration, company:, name: "SGST", calculation_method: "percentage", value: 9)

        send_request :post, api_v1_invoices_path(
          invoice: {
            client_id: client.id,
            invoice_number: "INV-MULTI-TAX-001",
            issue_date: Date.current.iso8601,
            due_date: 30.days.from_now.to_date.iso8601,
            status: "draft",
            currency: company.base_currency,
            invoice_taxes_attributes: [
              { tax_configuration_id: cgst.id },
              { tax_configuration_id: sgst.id }
            ],
            invoice_line_items_attributes: [
              {
                name: "Implementation",
                description: "Taxable work",
                date: Date.current.iso8601,
                rate: 100,
                quantity: 600
              }
            ]
          }), headers: auth_headers(user)

        expect(response).to have_http_status(:ok)

        invoice = Invoice.find_by!(invoice_number: "INV-MULTI-TAX-001")
        expect(invoice.tax.to_f).to eq(180.0)
        expect(invoice.amount.to_f).to eq(1180.0)
        expect(invoice.invoice_taxes.pluck(:name, :amount)).to match_array([
          ["CGST", 90.to_d],
          ["SGST", 90.to_d]
        ])
        expect(json_response.fetch("invoiceTaxes").pluck("name")).to match_array(["CGST", "SGST"])
      end

      it "creates an invoice in the client currency and returns it in the response" do
        client.update!(currency: "EUR")
        allow(CurrencyConversionService).to receive(:get_exchange_rate)
          .with("EUR", company.base_currency, kind_of(Date))
          .and_return(1.2)

        send_request :post, api_v1_invoices_path(
          invoice: {
            client_id: client.id,
            invoice_number: "INV-EUR-001",
            issue_date: Date.current.iso8601,
            due_date: 30.days.from_now.to_date.iso8601,
            status: "draft",
            currency: "EUR",
            invoice_line_items_attributes: [
              {
                name: "EUR strategy block",
                description: "Euro invoice",
                date: Date.current.iso8601,
                rate: 150,
                quantity: 120
              }
            ]
          }), headers: auth_headers(user)

        expect(response).to have_http_status(:ok)

        invoice = Invoice.find_by!(invoice_number: "INV-EUR-001")
        expect(invoice.currency).to eq("EUR")
        expect(invoice.amount.to_f).to eq(300.0)
        expect(invoice.base_currency_amount.to_f).to eq(360.0)
        expect(json_response["currency"]).to eq("EUR")
        expect(json_response["baseCurrencyAmount"].to_f).to eq(360.0)
        expect(json_response.dig("client", "currency")).to eq("EUR")
      end

      it "does not create invoices for clients from another workspace" do
        other_company = create(:company)
        other_client = create(:client, company: other_company)

        expect do
          send_request :post, api_v1_invoices_path(
            invoice: {
              client_id: other_client.id,
              invoice_number: "INV-CROSS-WORKSPACE-001",
              issue_date: Date.current.iso8601,
              due_date: 30.days.from_now.to_date.iso8601,
              status: "draft",
              currency: company.base_currency,
              invoice_line_items_attributes: [
                {
                  name: "Cross workspace attempt",
                  description: "Should not persist",
                  date: Date.current.iso8601,
                  rate: 100,
                  quantity: 60
                }
              ]
            }), headers: auth_headers(user)
        end.not_to change(Invoice, :count)

        expect(response).to have_http_status(:not_found)
      end

      it "supports USD, EUR, and INR invoices within the same company" do
        eur_client = create(:client, company:, currency: "EUR", name: "Euro Client")
        inr_client = create(:client, company:, currency: "INR", name: "India Client")

        allow(CurrencyConversionService).to receive(:get_exchange_rate)
          .with("EUR", company.base_currency, kind_of(Date))
          .and_return(1.2)
        allow(CurrencyConversionService).to receive(:get_exchange_rate)
          .with("INR", company.base_currency, kind_of(Date))
          .and_return(0.012)

        [
          [client, "INV-USD-001", "USD", 300.0],
          [eur_client, "INV-EUR-002", "EUR", 360.0],
          [inr_client, "INV-INR-001", "INR", 3.6]
        ].each do |invoice_client, invoice_number, currency_code, expected_base_amount|
          send_request :post, api_v1_invoices_path(
            invoice: {
              client_id: invoice_client.id,
              invoice_number: invoice_number,
              issue_date: Date.current.iso8601,
              due_date: 30.days.from_now.to_date.iso8601,
              status: "draft",
              currency: currency_code,
              invoice_line_items_attributes: [
                {
                  name: "#{currency_code} strategy block",
                  description: "#{currency_code} invoice",
                  date: Date.current.iso8601,
                  rate: 150,
                  quantity: 120
                }
              ]
            }), headers: auth_headers(user)

          expect(response).to have_http_status(:ok)

          created_invoice = Invoice.find_by!(invoice_number:)
          expect(created_invoice.company_id).to eq(company.id)
          expect(created_invoice.currency).to eq(currency_code)
          expect(created_invoice.base_currency_amount.to_f).to eq(expected_base_amount)
        end

        expect(
          Invoice.where(invoice_number: ["INV-USD-001", "INV-EUR-002", "INV-INR-001"]).order(:invoice_number).pluck(:currency)
        ).to eq(["EUR", "INR", "USD"])
      end

      it "rejects timesheet entries from another company" do
        other_company = create(:company)
        other_client = create(:client, company: other_company)
        other_project = create(:project, client: other_client)
        other_user = create(
          :user,
          email: "invoice-create-other-company@example.com",
          current_workspace_id: other_company.id
        )
        create(:employment, company: other_company, user: other_user)
        other_timesheet_entry = create(
          :timesheet_entry,
          user: other_user,
          project: other_project,
          work_date: Date.current,
          duration: 60
        )

        send_request :post, api_v1_invoices_path(
          invoice: {
            client_id: client.id,
            invoice_number: "INV-CROSS-WORKSPACE-001",
            issue_date: Date.current.iso8601,
            due_date: 30.days.from_now.to_date.iso8601,
            status: "draft",
            currency: company.base_currency,
            invoice_line_items_attributes: [
              {
                name: "Cross workspace entry",
                description: "Should fail",
                date: other_timesheet_entry.work_date.iso8601,
                rate: 100,
                quantity: 60,
                timesheet_entry_id: other_timesheet_entry.id
              }
            ]
          }), headers: auth_headers(user)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("not found")
      end

      context "when client doesn't exist" do
        it "throws 404" do
          send_request :post, api_v1_invoices_path(
            invoice: {
              client_id: 100000,
              invoice_number: "INV0001",
              reference: "bar",
              issue_date: "2022-01-01",
              due_date: "2022-01-31"
            }), headers: auth_headers(user)
          expect(response).to have_http_status(:not_found)
        end
      end
    end
  end

  context "when user is an employee" do
    before do
      create(:employment, company:, user:)
      user.add_role :employee, company
      sign_in user
      send_request :post, api_v1_invoices_path(
        invoice: attributes_for(
          :invoice,
          client:,
          client_id: client.id,
          invoice_line_item: {
            name: "Test",
            description: "test description",
            data: Faker::Date.in_date_period,
            rate: 12.4,
            quantity: 34.54
          }
        )
      ), headers: auth_headers(user)
    end

    it "is not be permitted to generate an invoice" do
      expect(response).to have_http_status(:forbidden)
    end
  end

  context "when user is a book keeper" do
    before do
      create(:employment, company:, user:)
      user.add_role :book_keeper, company
      sign_in user
      send_request :post, api_v1_invoices_path(
        invoice: attributes_for(
          :invoice,
          client:,
          client_id: client.id,
          invoice_line_item: {
            name: "Test",
            description: "test description",
            data: Faker::Date.in_date_period,
            rate: 12.4,
            quantity: 34.54
          }
        )
      ), headers: auth_headers(user)
    end

    it "is not be permitted to generate an invoice" do
      expect(response).to have_http_status(:forbidden)
    end
  end

  context "when unauthenticated" do
    it "is not be permitted to generate an invoice" do
      send_request :post, api_v1_invoices_path(
        invoice: attributes_for(
          :invoice,
          client:,
          client_id: client.id
        )
      )
      expect(response).to have_http_status(:unauthorized)
      expect(json_response["error"]).to eq(I18n.t("devise.failure.unauthenticated"))
    end
  end
end

# Generated by Descant: acceptance tests below.
RSpec.describe "Api::V1::Invoices#create", type: :request do
  let_it_be(:company) { create(:company, :with_logo, base_currency: "USD") }
  let_it_be(:client) { create(:client, company:) }
  let(:user) { create(:user, email: "reservation-sent-create-admin@example.com", current_workspace_id: company.id) }

  before do
    create(:employment, company:, user:)
    user.add_role :admin, company
    sign_in user
  end

  # "a second kept invoice on the same entry fails with \"entry is on another invoice\""
  # A caller chooses the status, so a sent invoice must not bypass the check that a draft gets.
  it "refuses a sent invoice created with an entry already on a kept draft and names no other invoice" do
    project = create(:project, client:, billable: true)
    entry = create(:timesheet_entry, user:, project:, bill_status: :unbilled, locked: false, work_date: Date.current)
    holder = create(:invoice, company:, client:, invoice_number: "HOLD-SEC-001")
    create(:invoice_line_item, invoice: holder, timesheet_entry: entry, rate: 100, quantity: 60)
    holder_lines_before = holder.invoice_line_items.pluck(:id)
    locked_before = entry.reload.locked

    expect do
      send_request :post, api_v1_invoices_path(
        invoice: {
          client_id: client.id,
          invoice_number: "SECOND-SEC-001",
          issue_date: Date.current.iso8601,
          due_date: 30.days.from_now.to_date.iso8601,
          status: "sent",
          currency: company.base_currency,
          invoice_line_items_attributes: [
            { name: "Work", date: Date.current.iso8601, rate: 100, quantity: 60, timesheet_entry_id: entry.id }
          ]
        }), headers: auth_headers(user)
    end.not_to change(Invoice, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("entry is on another invoice")
    expect(response.body).not_to include("HOLD-SEC-001")
    expect(response.body).not_to include("\"#{holder.id}\"")
    expect(holder.invoice_line_items.pluck(:id)).to eq(holder_lines_before)
    expect(entry.reload.locked).to eq(locked_before)
  end
end

RSpec.describe "Api::V1::Invoices#create", type: :request do
  let(:sent_create_company) { create(:company, base_currency: "USD") }
  let(:sent_create_client) { create(:client, company: sent_create_company) }
  let(:sent_create_admin) { create(:user, current_workspace_id: sent_create_company.id) }
  let(:sent_create_project) { create(:project, client: sent_create_client, billable: true) }

  before do
    create(:employment, company: sent_create_company, user: sent_create_admin)
    sent_create_admin.add_role :admin, sent_create_company
    sign_in sent_create_admin
  end

  # Saving a sent invoice keeps today's lock behaviour: only draft saves lock their entries,
  # so the seeded legacy "unlocked links" stay as they are.
  it "creating a sent invoice with direct and grouped entries leaves them unlocked and writes no intent" do
    direct_entry, grouped_entry = create_list(:timesheet_entry, 2, user: sent_create_admin, project: sent_create_project,
      bill_status: :unbilled, locked: false, work_date: Date.current, duration: 60)

    expect do
      send_request :post, api_v1_invoices_path, params: {
        invoice: {
          client_id: sent_create_client.id,
          invoice_number: "INV-SENT-NOLOCK-001",
          issue_date: Date.current.iso8601,
          due_date: 30.days.from_now.to_date.iso8601,
          status: "sent",
          currency: sent_create_company.base_currency,
          invoice_line_items_attributes: [
            { name: "Direct", description: "d", date: Date.current.iso8601, rate: 100, quantity: 60,
              timesheet_entry_id: direct_entry.id },
            { name: "Grouped", description: "g", date: Date.current.iso8601, rate: 100, quantity: 60,
              linked_timesheet_entry_ids: [grouped_entry.id] }
          ]
        }
      }, headers: auth_headers(sent_create_admin)
    end.not_to change(InvoiceOperationIntent, :count)

    expect(response).to have_http_status(:ok)
    expect([direct_entry.reload.locked, grouped_entry.reload.locked]).to eq([false, false])
  end
end

RSpec.describe "Api::V1::Invoices#create", type: :request do
  let(:sent_conflict_company) { create(:company, base_currency: "USD") }
  let(:sent_conflict_client) { create(:client, company: sent_conflict_company) }
  let(:sent_conflict_admin) { create(:user, current_workspace_id: sent_conflict_company.id) }
  let(:sent_conflict_project) { create(:project, client: sent_conflict_client, billable: true) }

  before do
    create(:employment, company: sent_conflict_company, user: sent_conflict_admin)
    sent_conflict_admin.add_role :admin, sent_conflict_company
    sign_in sent_conflict_admin
  end

  # "a second kept invoice on the same entry fails with \"entry is on another invoice\""
  it "creating a sent invoice with an entry already on a kept draft is refused with entry is on another invoice" do
    entry = create(:timesheet_entry, user: sent_conflict_admin, project: sent_conflict_project,
      bill_status: :unbilled, locked: false, work_date: Date.current, duration: 60)
    draft = create(:invoice, company: sent_conflict_company, client: sent_conflict_client)
    create(:invoice_line_item, invoice: draft, timesheet_entry: entry, rate: 100, quantity: 60)
    expect(entry.reload.locked).to be(true)

    expect do
      send_request :post, api_v1_invoices_path, params: {
        invoice: {
          client_id: sent_conflict_client.id,
          invoice_number: "INV-SENT-CONFLICT-001",
          issue_date: Date.current.iso8601,
          due_date: 30.days.from_now.to_date.iso8601,
          status: "sent",
          currency: sent_conflict_company.base_currency,
          invoice_line_items_attributes: [
            { name: "Same work", description: "dup", date: Date.current.iso8601, rate: 100, quantity: 60,
              timesheet_entry_id: entry.id }
          ]
        }
      }, headers: auth_headers(sent_conflict_admin)
    end.to not_change(Invoice, :count).and not_change(InvoiceLineItem, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("entry is on another invoice")
    expect(response.body).not_to include(draft.invoice_number)
    expect(entry.reload.locked).to be(true)
    expect(draft.reload.invoice_line_items.pluck(:timesheet_entry_id)).to eq([entry.id])
  end
end

RSpec.describe "Api::V1::Invoices#create", type: :request do
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
  # The sent invoice never locked its entries and has no holding: its lines alone must block a second invoice.
  it "creating a draft with an entry on an unlocked sent invoice with no holding is refused" do
    direct_entry, grouped_entry = create_list(:timesheet_entry, 2, user: unlocked_link_admin,
      project: unlocked_link_project, bill_status: :unbilled, locked: false, work_date: Date.current, duration: 60)
    sent = create(:invoice, company: unlocked_link_company, client: unlocked_link_client, status: :sent)
    create(:invoice_line_item, invoice: sent, timesheet_entry: direct_entry, rate: 100, quantity: 60)
    aggregate = create(:invoice_line_item, invoice: sent, timesheet_entry: nil, rate: 100, quantity: 60)
    create(:invoice_line_item_time_entry, invoice_line_item: aggregate, timesheet_entry: grouped_entry)
    InvoiceEntryHolding.where(company_id: unlocked_link_company.id, invoice_id: sent.id).delete_all
    TimesheetEntry.where(id: [direct_entry.id, grouped_entry.id]).update_all(locked: false)

    [direct_entry, grouped_entry].each_with_index do |entry, index|
      expect do
        send_request :post, api_v1_invoices_path, params: {
          invoice: {
            client_id: unlocked_link_client.id,
            invoice_number: "INV-UNLOCKED-LINK-#{index}",
            issue_date: Date.current.iso8601,
            due_date: 30.days.from_now.to_date.iso8601,
            status: "draft",
            currency: unlocked_link_company.base_currency,
            invoice_line_items_attributes: [
              { name: "Dup", description: "dup", date: Date.current.iso8601, rate: 100, quantity: 60,
                linked_timesheet_entry_ids: [entry.id] }
            ]
          }
        }, headers: auth_headers(unlocked_link_admin)
      end.not_to change(Invoice, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("entry is on another invoice")
      expect(entry.reload.locked).to be(false)
    end
  end
end

RSpec.describe "Api::V1::Invoices#create", type: :request do
  let(:nested_once_company) { create(:company, base_currency: "USD") }
  let(:nested_once_client) { create(:client, company: nested_once_company) }
  let(:nested_once_admin) { create(:user, current_workspace_id: nested_once_company.id) }
  let(:nested_once_project) { create(:project, client: nested_once_client, billable: true) }

  before do
    create(:employment, company: nested_once_company, user: nested_once_admin)
    nested_once_admin.add_role :admin, nested_once_company
    sign_in nested_once_admin
  end

  # "Nested `invoice_line_items_attributes` on create or update produce exactly one operation per request."
  it "a nested draft create with two entry lines writes exactly one intent and locks both entries" do
    first_entry, second_entry = create_list(:timesheet_entry, 2, user: nested_once_admin, project: nested_once_project,
      bill_status: :unbilled, locked: false, work_date: Date.current, duration: 60)

    expect do
      send_request :post, api_v1_invoices_path, params: {
        invoice: {
          client_id: nested_once_client.id,
          invoice_number: "INV-NESTED-ONCE-001",
          issue_date: Date.current.iso8601,
          due_date: 30.days.from_now.to_date.iso8601,
          status: "draft",
          currency: nested_once_company.base_currency,
          invoice_line_items_attributes: [
            { name: "One", description: "1", date: Date.current.iso8601, rate: 100, quantity: 60,
              timesheet_entry_id: first_entry.id },
            { name: "Two", description: "2", date: Date.current.iso8601, rate: 100, quantity: 60,
              linked_timesheet_entry_ids: [second_entry.id] }
          ]
        }
      }, headers: auth_headers(nested_once_admin)
    end.to change(InvoiceOperationIntent, :count).by(1)

    expect(response).to have_http_status(:ok)
    invoice = Invoice.find_by!(invoice_number: "INV-NESTED-ONCE-001")
    expect(InvoiceOperationIntent.where(invoice_id: invoice.id).count).to eq(1)
    expect([first_entry.reload.locked, second_entry.reload.locked]).to eq([true, true])
  end
end

RSpec.describe "Api::V1::Invoices#create", type: :request do
  let(:sent_conflict_company) { create(:company, base_currency: "USD") }
  let(:sent_conflict_client) { create(:client, company: sent_conflict_company) }
  let(:sent_conflict_admin) { create(:user, current_workspace_id: sent_conflict_company.id) }
  let(:sent_conflict_project) { create(:project, client: sent_conflict_client, billable: true) }

  before do
    create(:employment, company: sent_conflict_company, user: sent_conflict_admin)
    sent_conflict_admin.add_role :admin, sent_conflict_company
    sign_in sent_conflict_admin
  end

  # "a second kept invoice on the same entry fails with \"entry is on another invoice\""
  # Scenario: the caller picks status "sent", which changes no locks, to slip an entry past the conflict check.
  it "refuses a sent invoice created over the API with an entry already on a kept draft and writes nothing" do
    entry = create(:timesheet_entry, user: sent_conflict_admin, project: sent_conflict_project,
      bill_status: :unbilled, locked: false, work_date: Date.current, duration: 60)
    draft = create(:invoice, company: sent_conflict_company, client: sent_conflict_client)
    create(:invoice_line_item, invoice: draft, timesheet_entry: entry, rate: 100, quantity: 60)
    expect(entry.reload.locked).to be(true)
    intents_before = InvoiceOperationIntent.where(company_id: sent_conflict_company.id).count

    expect do
      send_request :post, api_v1_invoices_path(
        invoice: {
          client_id: sent_conflict_client.id,
          invoice_number: "INV-SENT-CONFLICT-001",
          issue_date: Date.current.iso8601,
          due_date: 30.days.from_now.to_date.iso8601,
          status: "sent",
          currency: sent_conflict_company.base_currency,
          invoice_line_items_attributes: [
            { name: "Work", description: "Work", date: Date.current.iso8601, rate: 100, quantity: 60,
              timesheet_entry_id: entry.id }
          ]
        }), headers: auth_headers(sent_conflict_admin)
    end.not_to change(Invoice, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("entry is on another invoice")
    expect(response.body).not_to include(draft.invoice_number)
    expect(Invoice.exists?(invoice_number: "INV-SENT-CONFLICT-001")).to be(false)
    expect(entry.reload.locked).to be(true)
    expect(draft.reload.invoice_line_items.pluck(:timesheet_entry_id)).to eq([entry.id])
    expect(InvoiceOperationIntent.where(company_id: sent_conflict_company.id).count).to eq(intents_before)
  end
end

RSpec.describe "Api::V1::Invoices#create", type: :request, committed_data: true do
  let(:abort_replay_company) { create(:company, base_currency: "USD") }
  let(:abort_replay_client) { create(:client, company: abort_replay_company) }
  let(:abort_replay_admin) { create(:user, current_workspace_id: abort_replay_company.id) }
  let(:abort_replay_project) { create(:project, client: abort_replay_client, billable: true) }

  before do
    create(:employment, company: abort_replay_company, user: abort_replay_admin)
    abort_replay_admin.add_role :admin, abort_replay_company
    sign_in abort_replay_admin
  end

  # "an API create with an entry on a kept invoice leaves a failed intent with one abort row"
  # "Commit applies the removals and is idempotent by operation_id; abort after a rollback finds nothing to undo."
  # Scenario: the abort row is delivered inline, then again by the worker and the recovery sweep.
  # None of those deliveries may unlock the entry the kept invoice still holds.
  it "keeps the other invoice's entry locked when the abort of a refused create is delivered again" do
    entry = create(:timesheet_entry, user: abort_replay_admin, project: abort_replay_project,
      bill_status: :unbilled, locked: false, work_date: Date.current, duration: 60)
    kept = create(:invoice, company: abort_replay_company, client: abort_replay_client)
    create(:invoice_line_item, invoice: kept, timesheet_entry: entry, rate: 100, quantity: 60)
    holding_before = InvoiceEntryHolding.find_by(company_id: abort_replay_company.id, invoice_id: kept.id).attributes

    send_request :post, api_v1_invoices_path(
      invoice: {
        client_id: abort_replay_client.id,
        invoice_number: "INV-ABORT-REPLAY-001",
        issue_date: Date.current.iso8601,
        due_date: 30.days.from_now.to_date.iso8601,
        status: "draft",
        currency: abort_replay_company.base_currency,
        invoice_line_items_attributes: [
          { name: "Work", description: "Work", date: Date.current.iso8601, rate: 100, quantity: 60,
            linked_timesheet_entry_ids: [entry.id] }
        ]
      }), headers: auth_headers(abort_replay_admin)

    expect(response).to have_http_status(:unprocessable_content)
    failed = InvoiceOperationIntent.where(company_id: abort_replay_company.id, state: "failed")
    expect(failed.count).to eq(1)
    abort_rows = InvoiceOperationOutboxItem.where(company_id: abort_replay_company.id,
      operation_id: failed.first.operation_id, kind: "abort")
    expect(abort_rows.count).to eq(1)

    request = Invoices::ReservationRequest.new(
      company_id: abort_replay_company.id, invoice_id: failed.first.invoice_id,
      operation_id: failed.first.operation_id, generation: failed.first.generation,
      disposition: failed.first.disposition, entries: failed.first.desired_entry_ids
    )
    2.times { Invoices::LegacyReservations.new.abort(request) }
    DeliverInvoiceOperationJob.perform_now(abort_rows.first.id)
    RecoverInvoiceOperationIntentsJob.perform_now

    expect(entry.reload.locked).to be(true)
    expect(InvoiceEntryHolding.find_by(company_id: abort_replay_company.id, invoice_id: kept.id).attributes)
      .to eq(holding_before)
    expect(abort_rows.count).to eq(1)
  end
end
