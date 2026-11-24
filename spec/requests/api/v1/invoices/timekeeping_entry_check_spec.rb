# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Invoices#create entry check under the timekeeping owner, unprojected direct entry", type: :request, committed_data: true do
  include PreparedReservationsSpecSupport

  let(:unprojected_company) { create(:company, base_currency: "USD") }
  let(:unprojected_client) { create(:client, company: unprojected_company) }
  let(:unprojected_admin) { create(:user, current_workspace_id: unprojected_company.id) }
  let(:unprojected_project) { create(:project, client: unprojected_client, billable: true) }
  let(:unprojected_fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  around do |example|
    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV => "http://timekeeping.test",
                         Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  before do
    create(:employment, company: unprojected_company, user: unprojected_admin)
    unprojected_admin.add_role :admin, unprojected_company
    sign_in unprojected_admin
  end

  # "Invoicing with the relay paused (AC5) passes on both seeded companies: a newly created entry is saved on a
  # draft invoice while the relay is paused, the projection lacks the row while paused, and shows it with
  # `locked: true` after resume"
  it "saves a draft line naming an entry the projection lacks and holds exactly one committed reservation for it" do
    TimekeepingOwnership.current.update!(owner: "timekeeping", handoff_step: nil)
    unprojected_fake.generation = TimekeepingOwnership.current.generation
    allow(Timekeeping::ReservationHttp).to receive(:new)
      .and_return(TimekeepingContract::FakeClient.new(timekeeping: unprojected_fake, relay: nil))
    entry_id = TimesheetEntry.maximum(:id).to_i + 500
    unprojected_fake.add_entry(company_id: unprojected_company.id, user_id: unprojected_admin.id,
                               project_id: unprojected_project.id, id: entry_id)
    expect(TimesheetEntry.exists?(entry_id)).to be(false)

    send_request :post, api_v1_invoices_path, params: {
      invoice: {
        client_id: unprojected_client.id, invoice_number: "INV-UNPROJECTED-001", issue_date: Date.current.iso8601,
        due_date: 30.days.from_now.to_date.iso8601, status: "draft", currency: unprojected_company.base_currency,
        invoice_line_items_attributes: [
          { name: "Paused", description: "AC5", date: Date.current.iso8601, rate: 100, quantity: 60,
            timesheet_entry_id: entry_id }
        ]
      }
    }, headers: auth_headers(unprojected_admin)

    expect(response).to have_http_status(:ok), response.body
    invoice = Invoice.find_by!(invoice_number: "INV-UNPROJECTED-001")
    expect(invoice.invoice_line_items.pluck(:timesheet_entry_id)).to eq([entry_id])
    expect(unprojected_fake.reservations_for(entry_id)).to eq([{ "invoice_id" => invoice.id, "state" => "committed" }])
    expect(unprojected_fake.entry_locked?(entry_id)).to be(true)
  end
end

RSpec.describe "Api::V1::Invoices#create entry check under the timekeeping owner, unprojected linked entry", type: :request, committed_data: true do
  include PreparedReservationsSpecSupport

  let(:linked_company) { create(:company, base_currency: "USD") }
  let(:linked_client) { create(:client, company: linked_company) }
  let(:linked_admin) { create(:user, current_workspace_id: linked_company.id) }
  let(:linked_project) { create(:project, client: linked_client, billable: true) }
  let(:linked_fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  around do |example|
    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV => "http://timekeeping.test",
                         Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  before do
    create(:employment, company: linked_company, user: linked_admin)
    linked_admin.add_role :admin, linked_company
    sign_in linked_admin
  end

  it "saves a draft line linking an entry the projection lacks and stores the link row by its id" do
    TimekeepingOwnership.current.update!(owner: "timekeeping", handoff_step: nil)
    linked_fake.generation = TimekeepingOwnership.current.generation
    allow(Timekeeping::ReservationHttp).to receive(:new)
      .and_return(TimekeepingContract::FakeClient.new(timekeeping: linked_fake, relay: nil))
    entry_id = TimesheetEntry.maximum(:id).to_i + 600
    linked_fake.add_entry(company_id: linked_company.id, user_id: linked_admin.id, project_id: linked_project.id,
                          id: entry_id)

    send_request :post, api_v1_invoices_path, params: {
      invoice: {
        client_id: linked_client.id, invoice_number: "INV-UNPROJECTED-LINK-001", issue_date: Date.current.iso8601,
        due_date: 30.days.from_now.to_date.iso8601, status: "draft", currency: linked_company.base_currency,
        invoice_line_items_attributes: [
          { name: "Grouped", description: "linked", date: Date.current.iso8601, rate: 100, quantity: 60,
            linked_timesheet_entry_ids: [entry_id] }
        ]
      }
    }, headers: auth_headers(linked_admin)

    expect(response).to have_http_status(:ok), response.body
    invoice = Invoice.find_by!(invoice_number: "INV-UNPROJECTED-LINK-001")
    line_ids = invoice.invoice_line_items.pluck(:id)
    expect(InvoiceLineItemTimeEntry.where(invoice_line_item_id: line_ids).pluck(:timesheet_entry_id)).to eq([entry_id])
    expect(linked_fake.reservations_for(entry_id)).to eq([{ "invoice_id" => invoice.id, "state" => "committed" }])
  end
end

RSpec.describe "Api::V1::Invoices#create entry check under the timekeeping owner, foreign entry", type: :request, committed_data: true do
  include PreparedReservationsSpecSupport

  let(:refusing_company) { create(:company, base_currency: "USD") }
  let(:refusing_client) { create(:client, company: refusing_company) }
  let(:refusing_admin) { create(:user, current_workspace_id: refusing_company.id) }
  let(:foreign_company) { create(:company) }
  let(:foreign_user) { create(:user, current_workspace_id: foreign_company.id) }
  let(:foreign_project) { create(:project, client: create(:client, company: foreign_company), billable: true) }
  let(:refusing_fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  around do |example|
    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV => "http://timekeeping.test",
                         Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  before do
    create(:employment, company: refusing_company, user: refusing_admin)
    refusing_admin.add_role :admin, refusing_company
    create(:employment, company: foreign_company, user: foreign_user)
    sign_in refusing_admin
  end

  def post_refusing_invoice(entry_ref)
    send_request :post, api_v1_invoices_path, params: {
      invoice: {
        client_id: refusing_client.id, invoice_number: "INV-FOREIGN-PAUSED-001", issue_date: Date.current.iso8601,
        due_date: 30.days.from_now.to_date.iso8601, status: "draft", currency: refusing_company.base_currency,
        invoice_line_items_attributes: [
          { name: "Foreign", description: "x", date: Date.current.iso8601, rate: 100, quantity: 60 }.merge(entry_ref)
        ]
      }
    }, headers: auth_headers(refusing_admin)
    [response.status, response.body]
  end

  # "While Timekeeping owns the data, the invoice line-item company check uses each entry's company from the
  # prepare response, as rule L8 says, and still refuses another company's entry with nothing changed"
  it "refuses another company's unprojected entry, twice alike, with no rows written and no reservation held" do
    TimekeepingOwnership.current.update!(owner: "timekeeping", handoff_step: nil)
    refusing_fake.generation = TimekeepingOwnership.current.generation
    allow(Timekeeping::ReservationHttp).to receive(:new)
      .and_return(TimekeepingContract::FakeClient.new(timekeeping: refusing_fake, relay: nil))
    foreign_id = TimesheetEntry.maximum(:id).to_i + 700
    refusing_fake.add_entry(company_id: foreign_company.id, user_id: foreign_user.id, project_id: foreign_project.id,
                            id: foreign_id)

    results = nil
    expect do
      results = [
        post_refusing_invoice(timesheet_entry_id: foreign_id),
        post_refusing_invoice(timesheet_entry_id: foreign_id),
        post_refusing_invoice(linked_timesheet_entry_ids: [foreign_id])
      ]
    end.to not_change(Invoice, :count)
      .and not_change(InvoiceLineItem, :count)
      .and not_change(InvoiceLineItemTimeEntry, :count)

    expect(results.map(&:first)).to eq([422, 422, 422])
    expect(results.uniq.size).to eq(1)
    expect(JSON.parse(results.first.last)["errors"]).to include("not found")
    expect(results.first.last).not_to include(foreign_id.to_s)
    expect(refusing_fake.reservations_for(foreign_id)).to eq([])
    expect(refusing_fake.entry_locked?(foreign_id)).to be(false)
  end
end

RSpec.describe "Invoice line saves under the timekeeping owner on a discarded draft", type: :request, committed_data: true do
  include PreparedReservationsSpecSupport

  let(:discarded_company) { create(:company, base_currency: "USD") }
  let(:discarded_client) { create(:client, company: discarded_company) }
  let(:discarded_other_company) { create(:company) }
  let(:discarded_other_user) { create(:user, current_workspace_id: discarded_other_company.id) }
  let(:discarded_other_project) do
    create(:project, client: create(:client, company: discarded_other_company), billable: true)
  end
  let(:discarded_fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  around do |example|
    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV => "http://timekeeping.test",
                         Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  # "While Timekeeping owns the data, the invoice line-item company check uses each entry's company from the
  # prepare response, as rule L8 says, and still refuses another company's entry with nothing changed"
  it "refuses a line naming another company's entry on a discarded draft and keeps no line row" do
    invoice = create(:invoice, company: discarded_company, client: discarded_client)
    invoice.discard!
    TimekeepingOwnership.current.update!(owner: "timekeeping", handoff_step: nil)
    discarded_fake.generation = TimekeepingOwnership.current.generation
    allow(Timekeeping::ReservationHttp).to receive(:new)
      .and_return(TimekeepingContract::FakeClient.new(timekeeping: discarded_fake, relay: nil))
    foreign_id = TimesheetEntry.maximum(:id).to_i + 900
    discarded_fake.add_entry(company_id: discarded_other_company.id, user_id: discarded_other_user.id,
                             project_id: discarded_other_project.id, id: foreign_id)

    expect do
      Timekeeping::BillingFence.transaction do
        InvoiceLineItem.create!(invoice: Invoice.with_discarded.find(invoice.id), name: "Late", date: Date.current,
                                rate: 100, quantity: 60, timesheet_entry_id: foreign_id)
      end
    end.to raise_error(Invoices::OperationErrors::Refused)

    expect(InvoiceLineItem.where(invoice_id: invoice.id)).to be_empty
    expect(discarded_fake.reservations_for(foreign_id)).to eq([])
  end
end

RSpec.describe "Api::V1::Invoices#create entry company check under the timekeeping owner", type: :request, committed_data: true do
  include PreparedReservationsSpecSupport

  let(:entry_check_company) { create(:company, base_currency: "USD") }
  let(:entry_check_client) { create(:client, company: entry_check_company) }
  let(:entry_check_admin) { create(:user, current_workspace_id: entry_check_company.id) }
  let(:entry_check_other_company) { create(:company) }
  let(:entry_check_other_user) { create(:user, current_workspace_id: entry_check_other_company.id) }
  let(:entry_check_other_project) do
    create(:project, client: create(:client, company: entry_check_other_company), billable: true)
  end
  let(:entry_check_fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  around do |example|
    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV => "http://timekeeping.test",
                         Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  before do
    create(:employment, company: entry_check_company, user: entry_check_admin)
    entry_check_admin.add_role :admin, entry_check_company
    create(:employment, company: entry_check_other_company, user: entry_check_other_user)
    sign_in entry_check_admin
  end

  def post_entry_check_invoice(number, entry_ref)
    send_request :post, api_v1_invoices_path, params: {
      invoice: {
        client_id: entry_check_client.id,
        invoice_number: number,
        issue_date: Date.current.iso8601,
        due_date: 30.days.from_now.to_date.iso8601,
        status: "draft",
        currency: entry_check_company.base_currency,
        invoice_line_items_attributes: [
          { name: "Entry", description: "line", date: Date.current.iso8601, rate: 100, quantity: 60 }.merge(entry_ref)
        ]
      }
    }, headers: auth_headers(entry_check_admin)
    [response.status, JSON.parse(response.body)["errors"]]
  end

  it "under the timekeeping owner another company's unprojected entry, direct or linked, is refused like a missing id and nothing is written or reserved" do
    TimekeepingOwnership.current.update!(owner: "timekeeping", handoff_step: nil)
    entry_check_fake.generation = TimekeepingOwnership.current.generation
    allow(Timekeeping::ReservationHttp).to receive(:new)
      .and_return(TimekeepingContract::FakeClient.new(timekeeping: entry_check_fake, relay: nil))

    # The other company's entry exists only in Timekeeping, as one logged while the relay is paused.
    foreign_entry_id = TimesheetEntry.maximum(:id).to_i + 5_000
    entry_check_fake.add_entry(company_id: entry_check_other_company.id, user_id: entry_check_other_user.id,
                               project_id: entry_check_other_project.id, id: foreign_entry_id)
    missing_id = foreign_entry_id + 1_000
    expect(TimesheetEntry.exists?(foreign_entry_id)).to be(false)

    foreign_direct = foreign_linked = nil
    expect do
      foreign_direct = post_entry_check_invoice("INV-TK-TENANT-001", timesheet_entry_id: foreign_entry_id)
      foreign_linked = post_entry_check_invoice("INV-TK-TENANT-002", linked_timesheet_entry_ids: [foreign_entry_id])
    end.to not_change(Invoice, :count)
      .and not_change(InvoiceLineItem, :count)
      .and not_change(InvoiceLineItemTimeEntry, :count)
      .and not_change(InvoiceEntryHolding, :count)

    missing_direct = post_entry_check_invoice("INV-TK-TENANT-003", timesheet_entry_id: missing_id)

    # "While Timekeeping owns the data, the invoice line-item company check uses each entry's company from the prepare response, as rule L8 says, and still refuses another company's entry with nothing changed"
    expect(foreign_direct).to eq([422, "entry not found"])
    expect(foreign_linked).to eq([422, "entry not found"])
    expect(foreign_direct).to eq(missing_direct)
    expect(entry_check_fake.reservations_for(foreign_entry_id)).to eq([])
    expect(entry_check_fake.entry_locked?(foreign_entry_id)).to be(false)
    # Every reservation request names the invoice's own company, never the entry's.
    reservation_paths = entry_check_fake.requests.pluck(:path).grep(%r{/reservations/})
    expect(reservation_paths).to all(start_with("/v1/companies/#{entry_check_company.id}/"))
  end
end

RSpec.describe "Api::V1::Invoices#create entry check under the timekeeping owner", type: :request, committed_data: true do
  include PreparedReservationsSpecSupport

  let(:check_company) { create(:company, base_currency: "USD") }
  let(:check_admin) { create(:user, current_workspace_id: check_company.id) }
  let(:check_client) { create(:client, company: check_company) }
  let(:check_project) { create(:project, client: check_client, billable: true) }
  let(:check_fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  around do |example|
    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV => "http://timekeeping.test",
                         Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  before do
    create(:employment, company: check_company, user: check_admin)
    check_admin.add_role :admin, check_company
    sign_in check_admin
  end

  it "under the timekeeping owner a draft invoice saves an entry Timekeeping holds but the projection lacks, and reserves it once" do
    TimekeepingOwnership.current.update!(owner: "timekeeping", handoff_step: nil)
    check_fake.generation = TimekeepingOwnership.current.generation
    allow(Timekeeping::ReservationHttp).to receive(:new)
      .and_return(TimekeepingContract::FakeClient.new(timekeeping: check_fake, relay: nil))
    entry_id = TimesheetEntry.maximum(:id).to_i + 1_000
    check_fake.add_entry(company_id: check_company.id, user_id: check_admin.id, project_id: check_project.id, id: entry_id)
    expect(TimesheetEntry.exists?(entry_id)).to be(false)

    send_request :post, api_v1_invoices_path, params: {
      invoice: {
        client_id: check_client.id, invoice_number: "INV-TK-UNPROJECTED-001",
        issue_date: Date.current.iso8601, due_date: 30.days.from_now.to_date.iso8601,
        status: "draft", currency: check_company.base_currency,
        invoice_line_items_attributes: [
          { name: "Relay paused", description: "AC5", date: Date.current.iso8601, rate: 100, quantity: 60,
            timesheet_entry_id: entry_id }
        ]
      }
    }, headers: auth_headers(check_admin)

    # "Relay paused: a newly created entry can be invoiced at once and appears in the entry list; the projection catches up when the relay resumes."
    expect(response).to have_http_status(:ok)
    invoice = Invoice.find_by!(invoice_number: "INV-TK-UNPROJECTED-001")
    expect(InvoiceLineItem.where(invoice_id: invoice.id).pluck(:timesheet_entry_id)).to eq([entry_id])
    expect(check_fake.reservations_for(entry_id)).to eq([{ "invoice_id" => invoice.id, "state" => "committed" }])
    expect(check_fake.entry_locked?(entry_id)).to be(true)
  end
end
