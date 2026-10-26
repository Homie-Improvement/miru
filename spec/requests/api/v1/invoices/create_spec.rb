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
RSpec.describe "Api::V1::Invoices#create direct entry id company scope", type: :request do
  let(:scope_company) { create(:company, base_currency: "USD") }
  let(:scope_client) { create(:client, company: scope_company) }
  let(:scope_admin) { create(:user, current_workspace_id: scope_company.id) }

  def direct_scope_invoice_params(entry_id, number)
    {
      invoice: {
        client_id: scope_client.id,
        invoice_number: number,
        issue_date: Date.current.iso8601,
        due_date: 30.days.from_now.to_date.iso8601,
        status: "draft",
        currency: scope_company.base_currency,
        invoice_line_items_attributes: [
          { name: "Entry", description: "line", date: Date.current.iso8601, rate: 100, quantity: 60, timesheet_entry_id: entry_id }
        ]
      }
    }
  end

  it "gives the same 422 not found body for a foreign direct timesheet entry id and a nonexistent one" do
    create(:employment, company: scope_company, user: scope_admin)
    scope_admin.add_role :admin, scope_company
    sign_in scope_admin

    other_company = create(:company)
    other_project = create(:project, client: create(:client, company: other_company), billable: true)
    other_user = create(:user, current_workspace_id: other_company.id)
    create(:employment, company: other_company, user: other_user)
    foreign_entry = create(:timesheet_entry, user: other_user, project: other_project, bill_status: "unbilled")
    missing_id = TimesheetEntry.maximum(:id).to_i + 1_000

    # "A missing id and a foreign id must both give the same `not_found` error, rendered through the existing 422 path."
    send_request :post, api_v1_invoices_path(direct_scope_invoice_params(foreign_entry.id, "INV-SCOPE-D1")), headers: auth_headers(scope_admin)
    foreign_status = response.status
    foreign_body = response.body

    send_request :post, api_v1_invoices_path(direct_scope_invoice_params(missing_id, "INV-SCOPE-D1")), headers: auth_headers(scope_admin)

    expect(foreign_status).to eq(422)
    expect(response.status).to eq(foreign_status)
    expect(foreign_body).to eq(response.body)
    expect(foreign_body).to include("not found")
    expect(foreign_body).not_to include("same company")
  end
end

RSpec.describe "Api::V1::Invoices#create linked entry ids company scope", type: :request do
  let(:linked_scope_company) { create(:company, base_currency: "USD") }
  let(:linked_scope_client) { create(:client, company: linked_scope_company) }
  let(:linked_scope_admin) { create(:user, current_workspace_id: linked_scope_company.id) }

  def linked_scope_invoice_params(entry_ids)
    {
      invoice: {
        client_id: linked_scope_client.id,
        invoice_number: "INV-SCOPE-L1",
        issue_date: Date.current.iso8601,
        due_date: 30.days.from_now.to_date.iso8601,
        status: "draft",
        currency: linked_scope_company.base_currency,
        invoice_line_items_attributes: [
          { name: "Aggregate", description: "line", date: Date.current.iso8601, rate: 100, quantity: 60, linked_timesheet_entry_ids: entry_ids }
        ]
      }
    }
  end

  it "gives the same 422 not found body for foreign and nonexistent linked timesheet entry ids without echoing the ids" do
    create(:employment, company: linked_scope_company, user: linked_scope_admin)
    linked_scope_admin.add_role :admin, linked_scope_company
    sign_in linked_scope_admin

    own_project = create(:project, client: linked_scope_client, billable: true)
    own_entry = create(:timesheet_entry, user: linked_scope_admin, project: own_project, bill_status: "unbilled")

    other_company = create(:company)
    other_project = create(:project, client: create(:client, company: other_company), billable: true)
    other_user = create(:user, current_workspace_id: other_company.id)
    create(:employment, company: other_company, user: other_user)
    foreign_entry = create(:timesheet_entry, user: other_user, project: other_project, bill_status: "unbilled")
    missing_id = TimesheetEntry.maximum(:id).to_i + 1_000

    # "A missing entry id and a foreign entry id give the same response, so no response reveals another company's entries"
    send_request :post, api_v1_invoices_path(linked_scope_invoice_params([own_entry.id, foreign_entry.id])), headers: auth_headers(linked_scope_admin)
    foreign_status = response.status
    foreign_body = response.body

    send_request :post, api_v1_invoices_path(linked_scope_invoice_params([own_entry.id, missing_id])), headers: auth_headers(linked_scope_admin)

    expect(foreign_status).to eq(422)
    expect(response.status).to eq(foreign_status)
    expect(foreign_body).to eq(response.body)
    expect(foreign_body).to include("not found")
    expect(foreign_body).not_to include(foreign_entry.id.to_s)
    expect(response.body).not_to include(missing_id.to_s)
  end
end

RSpec.describe "Api::V1::Invoices#create foreign entry writes nothing", type: :request do
  let(:nowrite_company) { create(:company, base_currency: "USD") }
  let(:nowrite_client) { create(:client, company: nowrite_company) }
  let(:nowrite_admin) { create(:user, current_workspace_id: nowrite_company.id) }

  it "writes nothing and leaves the foreign entry unlocked when a create names another company's entry" do
    create(:employment, company: nowrite_company, user: nowrite_admin)
    nowrite_admin.add_role :admin, nowrite_company
    sign_in nowrite_admin

    other_company = create(:company)
    other_project = create(:project, client: create(:client, company: other_company), billable: true)
    other_user = create(:user, current_workspace_id: other_company.id)
    create(:employment, company: other_company, user: other_user)
    foreign_direct = create(:timesheet_entry, user: other_user, project: other_project, bill_status: "unbilled")
    foreign_linked = create(:timesheet_entry, user: other_user, project: other_project, bill_status: "unbilled")
    TimesheetEntry.where(id: [foreign_direct.id, foreign_linked.id]).update_all(locked: false)
    expect(TimesheetEntry.where(id: [foreign_direct.id, foreign_linked.id]).pluck(:locked)).to eq([false, false])

    invoice_count = Invoice.count
    line_item_count = InvoiceLineItem.count
    join_count = InvoiceLineItemTimeEntry.count

    # "A create through `POST /api/v1/invoices` with another company's entry id returns not_found, writes nothing, and leaves that entry's `locked` unchanged."
    send_request :post, api_v1_invoices_path(
      invoice: {
        client_id: nowrite_client.id,
        invoice_number: "INV-SCOPE-NW1",
        issue_date: Date.current.iso8601,
        due_date: 30.days.from_now.to_date.iso8601,
        status: "draft",
        currency: nowrite_company.base_currency,
        invoice_line_items_attributes: [
          { name: "Direct", description: "line", date: Date.current.iso8601, rate: 100, quantity: 60, timesheet_entry_id: foreign_direct.id },
          { name: "Aggregate", description: "line", date: Date.current.iso8601, rate: 100, quantity: 60, linked_timesheet_entry_ids: [foreign_linked.id] }
        ]
      }), headers: auth_headers(nowrite_admin)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("not found")
    expect(Invoice.count).to eq(invoice_count)
    expect(InvoiceLineItem.count).to eq(line_item_count)
    expect(InvoiceLineItemTimeEntry.count).to eq(join_count)
    expect(foreign_direct.reload.locked).to be(false)
    expect(foreign_linked.reload.locked).to be(false)
  end
end

RSpec.describe "Api::V1::Invoices#create NULL company entry", type: :request do
  let(:null_scope_company) { create(:company, base_currency: "USD") }
  let(:null_scope_client) { create(:client, company: null_scope_company) }
  let(:null_scope_admin) { create(:user, current_workspace_id: null_scope_company.id) }

  def null_scope_invoice_params(entry_id)
    {
      invoice: {
        client_id: null_scope_client.id,
        invoice_number: "INV-SCOPE-N1",
        issue_date: Date.current.iso8601,
        due_date: 30.days.from_now.to_date.iso8601,
        status: "draft",
        currency: null_scope_company.base_currency,
        invoice_line_items_attributes: [
          { name: "Entry", description: "line", date: Date.current.iso8601, rate: 100, quantity: 60, timesheet_entry_id: entry_id }
        ]
      }
    }
  end

  it "refuses an entry whose company_id is NULL with the same 422 body as a nonexistent id" do
    create(:employment, company: null_scope_company, user: null_scope_admin)
    null_scope_admin.add_role :admin, null_scope_company
    sign_in null_scope_admin

    own_project = create(:project, client: null_scope_client, billable: true)
    null_entry = create(:timesheet_entry, user: null_scope_admin, project: own_project, bill_status: "unbilled")
    null_entry.update_column(:company_id, nil)
    expect(null_entry.reload.company_id).to be_nil
    missing_id = TimesheetEntry.maximum(:id).to_i + 1_000

    # "A row whose `company_id` is NULL is not_found, never accepted for every company."
    send_request :post, api_v1_invoices_path(null_scope_invoice_params(null_entry.id)), headers: auth_headers(null_scope_admin)
    null_status = response.status
    null_body = response.body

    send_request :post, api_v1_invoices_path(null_scope_invoice_params(missing_id)), headers: auth_headers(null_scope_admin)

    expect(null_status).to eq(422)
    expect(null_body).to include("not found")
    expect(response.status).to eq(null_status)
    expect(null_body).to eq(response.body)
    expect(Invoice.where(invoice_number: "INV-SCOPE-N1")).to be_empty
  end
end

RSpec.describe "Api::V1::Invoices#create with another company's linked entry", type: :request do
  it "a refused create naming another company's linked entry writes nothing and stays refused when sent again" do
    company = create(:company, base_currency: "USD")
    client = create(:client, company:)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role :admin, company
    sign_in user

    other_company = create(:company)
    other_project = create(:project, client: create(:client, company: other_company), billable: true)
    other_user = create(:user, current_workspace_id: other_company.id)
    create(:employment, company: other_company, user: other_user)
    foreign_entry = create(
      :timesheet_entry,
      user: other_user,
      project: other_project,
      bill_status: :unbilled,
      locked: false,
      work_date: Date.current,
      duration: 60
    )
    # The baseline must hold the seeded value, or an unchanged comparison proves nothing.
    expect(foreign_entry.reload.locked).to be(false)

    invoice_params = {
      client_id: client.id,
      invoice_number: "INV-FOREIGN-LINKED-RETRY-001",
      issue_date: Date.current.iso8601,
      due_date: 30.days.from_now.to_date.iso8601,
      status: "draft",
      currency: company.base_currency,
      invoice_line_items_attributes: [
        {
          name: "Foreign aggregate",
          description: "Should fail",
          date: Date.current.iso8601,
          rate: 100,
          quantity: 60,
          linked_timesheet_entry_ids: [foreign_entry.id]
        }
      ]
    }

    # "A create through `POST /api/v1/invoices` with another company's entry id returns not_found, writes nothing, and leaves that entry's `locked` unchanged."
    bodies = Array.new(2) do
      expect do
        send_request :post, api_v1_invoices_path(invoice: invoice_params), headers: auth_headers(user)
      end.to not_change(Invoice, :count)
        .and not_change(InvoiceLineItem, :count)
        .and not_change(InvoiceLineItemTimeEntry, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("not found")
      response.body
    end

    expect(bodies.uniq.size).to eq(1)
    expect(bodies.first).not_to include(foreign_entry.id.to_s)
    expect(foreign_entry.reload.locked).to be(false)
  end
end

RSpec.describe "Api::V1::Invoices#create with a direct entry id outside the company", type: :request do
  let(:scoped_company) { create(:company, base_currency: "USD") }
  let(:scoped_client) { create(:client, company: scoped_company) }
  let(:scoped_admin) { create(:user, current_workspace_id: scoped_company.id) }

  before do
    create(:employment, company: scoped_company, user: scoped_admin)
    scoped_admin.add_role :admin, scoped_company
    sign_in scoped_admin
  end

  def post_with_direct_entry_id(entry_id, number)
    send_request :post, api_v1_invoices_path(
      invoice: {
        client_id: scoped_client.id,
        invoice_number: number,
        issue_date: Date.current.iso8601,
        due_date: 30.days.from_now.to_date.iso8601,
        status: "draft",
        currency: scoped_company.base_currency,
        invoice_line_items_attributes: [
          { name: "Entry", description: "line", date: Date.current.iso8601, rate: 100, quantity: 60,
            timesheet_entry_id: entry_id }
        ]
      }), headers: auth_headers(scoped_admin)
    [response.status, response.body]
  end

  it "a foreign direct entry id and a nonexistent direct entry id give the identical not found response and write nothing" do
    other_company = create(:company)
    other_project = create(:project, client: create(:client, company: other_company), billable: true)
    other_user = create(:user, current_workspace_id: other_company.id)
    foreign_entry = create(:timesheet_entry, user: other_user, project: other_project, bill_status: "unbilled")
    foreign_entry.update_column(:locked, false)
    expect(foreign_entry.reload.locked).to be(false)
    missing_id = TimesheetEntry.maximum(:id).to_i + 1_000

    # "A missing id and a foreign id must both give the same `not_found` error, rendered through the existing 422 path."
    foreign_result = nil
    expect {
      foreign_result = post_with_direct_entry_id(foreign_entry.id, "INV-FOREIGN-DIRECT")
    }.not_to change { [Invoice.count, InvoiceLineItem.count, InvoiceLineItemTimeEntry.count] }
    missing_result = post_with_direct_entry_id(missing_id, "INV-MISSING-DIRECT")

    expect(foreign_result.first).to eq(422)
    expect(foreign_result).to eq(missing_result)
    expect(foreign_result.last).to include("not found")
    expect(foreign_result.last).not_to include(foreign_entry.id.to_s)
    expect(foreign_entry.reload.locked).to be(false)
  end
end

RSpec.describe "Api::V1::Invoices#create with a NULL-company entry", type: :request do
  let(:null_company) { create(:company, base_currency: "USD") }
  let(:null_client) { create(:client, company: null_company) }
  let(:null_admin) { create(:user, current_workspace_id: null_company.id) }

  before do
    create(:employment, company: null_company, user: null_admin)
    null_admin.add_role :admin, null_company
    sign_in null_admin
  end

  def post_with_entry_ids(direct_id, linked_ids, number)
    send_request :post, api_v1_invoices_path(
      invoice: {
        client_id: null_client.id,
        invoice_number: number,
        issue_date: Date.current.iso8601,
        due_date: 30.days.from_now.to_date.iso8601,
        status: "draft",
        currency: null_company.base_currency,
        invoice_line_items_attributes: [
          { name: "Entry", description: "line", date: Date.current.iso8601, rate: 100, quantity: 60,
            timesheet_entry_id: direct_id, linked_timesheet_entry_ids: linked_ids }.compact
        ]
      }), headers: auth_headers(null_admin)
    [response.status, response.body]
  end

  it "an entry with NULL company_id is not found on create, with the nonexistent-id response, and nothing is written" do
    project = create(:project, client: null_client, billable: true)
    null_entry = create(:timesheet_entry, user: null_admin, project:, bill_status: "unbilled")
    null_entry.update_column(:company_id, nil)
    expect(null_entry.reload.company_id).to be_nil
    missing_id = TimesheetEntry.maximum(:id).to_i + 1_000

    # "A row whose `company_id` is NULL is not_found, never accepted for every company."
    direct_null = nil
    linked_null = nil
    expect {
      direct_null = post_with_entry_ids(null_entry.id, nil, "INV-NULL-DIRECT")
      linked_null = post_with_entry_ids(nil, [null_entry.id], "INV-NULL-LINKED")
    }.not_to change { [Invoice.count, InvoiceLineItem.count, InvoiceLineItemTimeEntry.count] }

    expect(direct_null.first).to eq(422)
    expect(direct_null).to eq(post_with_entry_ids(missing_id, nil, "INV-MISSING-DIRECT-2"))
    expect(linked_null.first).to eq(422)
    expect(linked_null).to eq(post_with_entry_ids(nil, [missing_id], "INV-MISSING-LINKED-2"))
    expect(direct_null.last).to include("not found")
  end
end

RSpec.describe "Api::V1::Invoices#create with a NULL-company timesheet entry", type: :request do
  it "answers a NULL-company entry id exactly like a nonexistent id and creates no invoice" do
    company = create(:company, :with_logo, base_currency: "USD")
    client = create(:client, company:)
    user = create(:user, email: "invoice-create-null-company@example.com", current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role :admin, company
    sign_in user
    project = create(:project, client:, billable: true)
    null_company_entry = create(:timesheet_entry, user:, project:, bill_status: "unbilled", work_date: Date.current, duration: 60)
    # update_column skips the before_save that would fill company_id from the project again.
    null_company_entry.update_column(:company_id, nil)
    missing_id = TimesheetEntry.maximum(:id).to_i + 1_000

    post_with_entry = lambda do |entry_id|
      send_request :post, api_v1_invoices_path(
        invoice: {
          client_id: client.id,
          invoice_number: "INV-NULL-COMPANY-001",
          issue_date: Date.current.iso8601,
          due_date: 30.days.from_now.to_date.iso8601,
          status: "draft",
          currency: company.base_currency,
          invoice_line_items_attributes: [
            { name: "Entry", description: "Should fail", date: Date.current.iso8601, rate: 100, quantity: 60, timesheet_entry_id: entry_id }
          ]
        }), headers: auth_headers(user)
      [response.status, response.body]
    end

    # "A row whose `company_id` is NULL is not_found, never accepted for every company."
    null_result = post_with_entry.call(null_company_entry.id)
    missing_result = post_with_entry.call(missing_id)

    expect(null_result.first).to eq(422)
    expect(null_result.last).to include("not found")
    expect(null_result).to eq(missing_result)
    expect(Invoice.where(company_id: company.id).count).to eq(0)
  end
end

RSpec.describe "Api::V1::Invoices#create with a direct timesheet entry outside the company", type: :request do
  it "gives the same 422 not found for a foreign and a nonexistent timesheet_entry_id and writes nothing" do
    company = create(:company, base_currency: "USD")
    client = create(:client, company:)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role :admin, company
    sign_in user

    other_company = create(:company)
    other_project = create(:project, client: create(:client, company: other_company), billable: true)
    other_user = create(:user, current_workspace_id: other_company.id)
    create(:employment, company: other_company, user: other_user)
    foreign_entry = create(:timesheet_entry, user: other_user, project: other_project, bill_status: "unbilled",
      locked: false, work_date: Date.current, duration: 60)
    expect(foreign_entry.reload.locked).to be(false)
    expect(foreign_entry.company_id).to eq(other_company.id)
    missing_id = TimesheetEntry.maximum(:id).to_i + 1_000

    params_for = lambda do |entry_id|
      {
        invoice: {
          client_id: client.id,
          invoice_number: "INV-FOREIGN-DIRECT-001",
          issue_date: Date.current.iso8601,
          due_date: 30.days.from_now.to_date.iso8601,
          status: "draft",
          currency: company.base_currency,
          invoice_line_items_attributes: [
            { name: "Entry", description: "Entry", date: Date.current.iso8601, rate: 100, quantity: 60,
              timesheet_entry_id: entry_id }
          ]
        }
      }
    end

    # "A create through `POST /api/v1/invoices` with another company's entry id returns not_found, writes nothing, and leaves that entry's `locked` unchanged."
    expect do
      send_request :post, api_v1_invoices_path, params: params_for.call(foreign_entry.id), headers: auth_headers(user)
    end.not_to change { [Invoice.count, InvoiceLineItem.count, InvoiceLineItemTimeEntry.count] }
    foreign_status = response.status
    foreign_body = response.body
    expect(foreign_entry.reload.locked).to be(false)

    send_request :post, api_v1_invoices_path, params: params_for.call(missing_id), headers: auth_headers(user)

    # "A nonexistent id gives the identical response."
    expect(foreign_status).to eq(422)
    expect(JSON.parse(foreign_body)["errors"]).to include("not found")
    expect(foreign_body).not_to include("same company")
    expect([response.status, response.body]).to eq([foreign_status, foreign_body])
  end
end

RSpec.describe "Api::V1::Invoices#create with linked timesheet entries outside the company", type: :request do
  it "gives the same 422 not found for foreign and nonexistent linked_timesheet_entry_ids without echoing the ids" do
    company = create(:company, base_currency: "USD")
    client = create(:client, company:)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role :admin, company
    sign_in user
    own_project = create(:project, client:, billable: true)
    own_entry = create(:timesheet_entry, user:, project: own_project, bill_status: "unbilled", locked: false,
      work_date: Date.current)

    other_company = create(:company)
    other_project = create(:project, client: create(:client, company: other_company), billable: true)
    other_user = create(:user, current_workspace_id: other_company.id)
    create(:employment, company: other_company, user: other_user)
    foreign_entry = create(:timesheet_entry, user: other_user, project: other_project, bill_status: "unbilled",
      locked: false, work_date: Date.current)
    expect(foreign_entry.reload.locked).to be(false)
    missing_id = TimesheetEntry.maximum(:id).to_i + 1_000

    params_for = lambda do |entry_id|
      {
        invoice: {
          client_id: client.id,
          invoice_number: "INV-FOREIGN-LINKED-001",
          issue_date: Date.current.iso8601,
          due_date: 30.days.from_now.to_date.iso8601,
          status: "draft",
          currency: company.base_currency,
          invoice_line_items_attributes: [
            { name: own_project.name, description: "Aggregate", date: Date.current.iso8601, rate: 100, quantity: 60,
              linked_timesheet_entry_ids: [own_entry.id, entry_id] }
          ]
        }
      }
    end

    expect do
      send_request :post, api_v1_invoices_path, params: params_for.call(foreign_entry.id), headers: auth_headers(user)
    end.not_to change { [Invoice.count, InvoiceLineItem.count, InvoiceLineItemTimeEntry.count] }
    foreign_status = response.status
    foreign_body = response.body
    expect([own_entry.reload.locked, foreign_entry.reload.locked]).to eq([false, false])

    send_request :post, api_v1_invoices_path, params: params_for.call(missing_id), headers: auth_headers(user)

    # "A missing id and a foreign id must both give the same `not_found` error, rendered through the existing 422 path."
    expect(foreign_status).to eq(422)
    expect(JSON.parse(foreign_body)["errors"]).to include("not found")
    expect([response.status, response.body]).to eq([foreign_status, foreign_body])
    expect(foreign_body).not_to include(foreign_entry.id.to_s)
    expect(response.body).not_to include(missing_id.to_s)
  end
end

RSpec.describe "Api::V1::Invoices#create with a timesheet entry that has no company", type: :request do
  it "refuses an own-project timesheet entry whose company_id is NULL with the nonexistent-id response" do
    company = create(:company, base_currency: "USD")
    client = create(:client, company:)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role :admin, company
    sign_in user
    project = create(:project, client:, billable: true)
    null_company_entry = create(:timesheet_entry, user:, project:, bill_status: "unbilled", locked: false,
      work_date: Date.current, duration: 60)
    # update_column skips the callback that would refill company_id from the project.
    null_company_entry.update_column(:company_id, nil)
    expect(null_company_entry.reload.company_id).to be_nil
    missing_id = TimesheetEntry.maximum(:id).to_i + 1_000

    params_for = lambda do |entry_id|
      {
        invoice: {
          client_id: client.id,
          invoice_number: "INV-NULL-COMPANY-001",
          issue_date: Date.current.iso8601,
          due_date: 30.days.from_now.to_date.iso8601,
          status: "draft",
          currency: company.base_currency,
          invoice_line_items_attributes: [
            { name: "Entry", description: "Entry", date: Date.current.iso8601, rate: 100, quantity: 60,
              timesheet_entry_id: entry_id }
          ]
        }
      }
    end

    # "A row whose `company_id` is NULL is not_found, never accepted for every company."
    expect do
      send_request :post, api_v1_invoices_path, params: params_for.call(null_company_entry.id), headers: auth_headers(user)
    end.not_to change(Invoice, :count)
    null_result = [response.status, response.body]

    send_request :post, api_v1_invoices_path, params: params_for.call(missing_id), headers: auth_headers(user)

    expect(null_result.first).to eq(422)
    expect(JSON.parse(null_result.last)["errors"]).to include("not found")
    expect([response.status, response.body]).to eq(null_result)
  end
end

RSpec.describe "Api::V1::Invoices#create with mixed linked entry ids", type: :request do
  it "gives one identical 422 when a valid linked entry is mixed with a foreign id or a nonexistent id, and writes nothing" do
    company = create(:company, base_currency: "USD")
    client = create(:client, company:)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role :admin, company
    sign_in user
    own_project = create(:project, client:, billable: true)
    own_entry = create(:timesheet_entry, user:, project: own_project, bill_status: :unbilled, locked: false, work_date: Date.current)

    other_company = create(:company)
    other_user = create(:user, current_workspace_id: other_company.id)
    create(:employment, company: other_company, user: other_user)
    other_project = create(:project, client: create(:client, company: other_company), billable: true)
    # An entry that really exists in a second company and is on no invoice.
    foreign_entry = create(:timesheet_entry, user: other_user, project: other_project, bill_status: :unbilled, locked: false, work_date: Date.current)
    missing_id = TimesheetEntry.maximum(:id).to_i + 1_000
    expect([own_entry.reload.locked, foreign_entry.reload.locked]).to eq([false, false])

    post_linked = lambda do |invoice_number, bad_id|
      send_request :post, api_v1_invoices_path(
        invoice: {
          client_id: client.id,
          invoice_number:,
          issue_date: Date.current.iso8601,
          due_date: 30.days.from_now.to_date.iso8601,
          status: "draft",
          currency: company.base_currency,
          invoice_line_items_attributes: [
            {
              name: own_project.name,
              description: "Aggregated work",
              date: Date.current.iso8601,
              rate: 100,
              quantity: 120,
              linked_timesheet_entry_ids: [own_entry.id, bad_id]
            }
          ]
        }), headers: auth_headers(user)
      [response.status, response.body]
    end

    # "A missing entry id and a foreign entry id give the same response, so no response reveals another company's entries"
    foreign_result = nil
    missing_result = nil
    expect do
      foreign_result = post_linked.call("INV-MIX-FOREIGN", foreign_entry.id)
      missing_result = post_linked.call("INV-MIX-MISSING", missing_id)
    end.to not_change(Invoice, :count)
      .and not_change(InvoiceLineItem, :count)
      .and not_change(InvoiceLineItemTimeEntry, :count)

    expect(foreign_result.first).to eq(422)
    expect(foreign_result).to eq(missing_result)
    expect(foreign_result.last).to include("not found")
    expect(foreign_result.last).not_to include(foreign_entry.id.to_s)
    expect(missing_result.last).not_to include(missing_id.to_s)
    # "writes nothing, and leaves that entry's `locked` unchanged"
    expect([own_entry.reload.locked, foreign_entry.reload.locked]).to eq([false, false])
  end
end

RSpec.describe "Api::V1::Invoices#create with a NULL-company entry", type: :request do
  it "answers a direct entry with NULL company_id in this company's project exactly as a nonexistent id" do
    company = create(:company, base_currency: "USD")
    client = create(:client, company:)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role :admin, company
    sign_in user
    project = create(:project, client:, billable: true)
    null_company_entry = create(:timesheet_entry, user:, project:, bill_status: :unbilled, locked: false, work_date: Date.current)
    # The save callback refills company_id, so the column is cleared without callbacks.
    null_company_entry.update_column(:company_id, nil)
    missing_id = TimesheetEntry.maximum(:id).to_i + 1_000

    post_direct = lambda do |invoice_number, entry_id|
      send_request :post, api_v1_invoices_path(
        invoice: {
          client_id: client.id,
          invoice_number:,
          issue_date: Date.current.iso8601,
          due_date: 30.days.from_now.to_date.iso8601,
          status: "draft",
          currency: company.base_currency,
          invoice_line_items_attributes: [
            {
              name: "Entry",
              description: "Direct entry",
              date: Date.current.iso8601,
              rate: 100,
              quantity: 60,
              timesheet_entry_id: entry_id
            }
          ]
        }), headers: auth_headers(user)
      [response.status, response.body]
    end

    # "A row whose `company_id` is NULL is not_found, never accepted for every company."
    null_result = nil
    expect do
      null_result = post_direct.call("INV-NULL-COMPANY", null_company_entry.id)
    end.not_to change(Invoice, :count)
    missing_result = post_direct.call("INV-NULL-MISSING", missing_id)

    expect(null_result.first).to eq(422)
    expect(null_result).to eq(missing_result)
    expect(null_result.last).to include("not found")
    expect(null_company_entry.reload.locked).to be(false)
  end
end
