# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Invoices::BulkDeletion#create under the timekeeping owner", type: :request, committed_data: true do
  include PreparedReservationsSpecSupport

  let(:bulk_tk_company) { create(:company) }
  let(:bulk_tk_admin) { create(:user, current_workspace_id: bulk_tk_company.id) }
  let(:bulk_tk_client) { create(:client, company: bulk_tk_company) }
  let(:bulk_tk_fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  around do |example|
    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV => "http://timekeeping.test",
                         Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  before do
    create(:employment, company: bulk_tk_company, user: bulk_tk_admin)
    bulk_tk_admin.add_role :admin, bulk_tk_company
    sign_in bulk_tk_admin
  end

  # "A mixed bulk delete settles each invoice on its own, and the paid invoice's reservations are unchanged"
  it "under the timekeeping owner a mixed bulk delete commits each destroyed invoice's own operation and leaves the paid invoice's reservations unchanged" do
    TimekeepingOwnership.current.update!(owner: "timekeeping", handoff_step: nil)
    bulk_tk_fake.generation = TimekeepingOwnership.current.generation
    allow(Timekeeping::ReservationHttp).to receive(:new)
      .and_return(TimekeepingContract::FakeClient.new(timekeeping: bulk_tk_fake, relay: nil))
    first_entry, second_entry, paid_entry = Array.new(3) { prepared_spec_projected_entry(bulk_tk_company) }
    [first_entry, second_entry, paid_entry].each do |row|
      bulk_tk_fake.add_entry(company_id: bulk_tk_company.id, user_id: row.user_id, project_id: row.project_id, id: row.id)
    end

    first = create(:invoice, company: bulk_tk_company, client: bulk_tk_client)
    create(:invoice_line_item, invoice: first, timesheet_entry: first_entry, rate: 100, quantity: 60)
    second = create(:invoice, company: bulk_tk_company, client: bulk_tk_client)
    create(:invoice_line_item, invoice: second, timesheet_entry: second_entry, rate: 100, quantity: 60)
    paid = create(:invoice, company: bulk_tk_company, client: bulk_tk_client, amount_due: 300)
    create(:invoice_line_item, invoice: paid, timesheet_entry: paid_entry, rate: 100, quantity: 60)
    create(:payment, invoice: paid, amount: 300)

    paid_before = bulk_tk_fake.reservations_for(paid_entry.id)
    expect(paid_before).to eq([{ "invoice_id" => paid.id, "state" => "committed" }])
    log_start = bulk_tk_fake.requests.size

    send_request :post, api_v1_invoices_bulk_deletion_index_path,
      params: { invoices_ids: [first.id, second.id, paid.id] }, headers: auth_headers(bulk_tk_admin)

    expect(response).to have_http_status(:unprocessable_content)
    expect(Invoice.exists?(first.id)).to be(false)
    expect(Invoice.exists?(second.id)).to be(false)
    expect(Invoice.exists?(paid.id)).to be(true)

    sent = bulk_tk_fake.requests.drop(log_start)
    reservation_calls = sent.select { |request| request[:path].match?(%r{/reservations/(prepare|commit|abort)\z}) }
    expect(reservation_calls.map { |request| request[:body]["invoice_id"] }).not_to include(paid.id)

    [first, second].each do |destroyed|
      own_prepares = reservation_calls.select do |request|
        request[:path].end_with?("/reservations/prepare") && request[:body]["invoice_id"] == destroyed.id
      end
      operation_ids = own_prepares.map { |request| request[:body]["operation_id"] }.uniq
      expect(operation_ids.size).to eq(1)
      commits = reservation_calls.select do |request|
        request[:path].end_with?("/reservations/commit") && request[:body]["operation_id"] == operation_ids.first
      end
      expect(commits.size).to be >= 1
      expect(commits.first[:body]["invoice_id"]).to eq(destroyed.id)
    end
    expect(reservation_calls.filter_map { |r| r[:body]["operation_id"] if r[:path].end_with?("/reservations/prepare") }
      .uniq.size).to eq(2)

    expect(bulk_tk_fake.reservations_for(first_entry.id)).to eq([])
    expect(bulk_tk_fake.reservations_for(second_entry.id)).to eq([])
    expect(bulk_tk_fake.entry_locked?(first_entry.id)).to be(false)
    expect(bulk_tk_fake.reservations_for(paid_entry.id)).to eq(paid_before)
    expect(bulk_tk_fake.entry_locked?(paid_entry.id)).to be(true)
  end
end

RSpec.describe "Api::V1::Invoices#update under the timekeeping owner for an invoice saved before holdings", type: :request, committed_data: true do
  include PreparedReservationsSpecSupport

  let(:legacy_tk_company) { create(:company, base_currency: "USD") }
  let(:legacy_tk_admin) { create(:user, current_workspace_id: legacy_tk_company.id) }
  let(:legacy_tk_client) { create(:client, company: legacy_tk_company) }
  let(:legacy_tk_fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  around do |example|
    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV => "http://timekeeping.test",
                         Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  before do
    create(:employment, company: legacy_tk_company, user: legacy_tk_admin)
    legacy_tk_admin.add_role :admin, legacy_tk_company
    sign_in legacy_tk_admin
  end

  # "an existing reservation with no intent: a line is removed from a sent invoice, then an entry is added in a separate transaction, and the old entry stays reserved"
  it "under the timekeeping owner a sent invoice with no holding or intent keeps a removed line's entry reserved after a later addition" do
    old_entry = prepared_spec_projected_entry(legacy_tk_company)
    new_entry = prepared_spec_projected_entry(legacy_tk_company)
    sent = create(:invoice, company: legacy_tk_company, client: legacy_tk_client, status: :sent)
    old_line = create(:invoice_line_item, invoice: sent, timesheet_entry: old_entry, rate: 100, quantity: 60)
    kept_line = create(:invoice_line_item, invoice: sent, timesheet_entry: nil, name: "Kept", rate: 50, quantity: 30)
    # An invoice saved before the boundary existed has no holding row.
    InvoiceEntryHolding.where(company_id: legacy_tk_company.id, invoice_id: sent.id).delete_all

    TimekeepingOwnership.current.update!(owner: "timekeeping", handoff_step: nil)
    legacy_tk_fake.generation = TimekeepingOwnership.current.generation
    allow(Timekeeping::ReservationHttp).to receive(:new)
      .and_return(TimekeepingContract::FakeClient.new(timekeeping: legacy_tk_fake, relay: nil))
    [old_entry, new_entry].each do |row|
      legacy_tk_fake.add_entry(company_id: legacy_tk_company.id, user_id: row.user_id, project_id: row.project_id, id: row.id)
    end
    legacy_tk_fake.add_reservation(entry_id: old_entry.id, invoice_id: sent.id, state: "committed", disposition: "active")

    invoice_fields = {
      client_id: legacy_tk_client.id, invoice_number: sent.invoice_number, issue_date: sent.issue_date.iso8601,
      due_date: sent.due_date.iso8601, status: "sent", currency: legacy_tk_company.base_currency
    }
    kept_attributes = { id: kept_line.id, name: "Kept", date: kept_line.date.iso8601, rate: 50, quantity: 30 }

    send_request :patch, api_v1_invoice_path(sent), params: {
      invoice: invoice_fields.merge(invoice_line_items_attributes: [
        kept_attributes,
        { id: old_line.id, name: old_line.name, date: old_line.date.iso8601, rate: 100, quantity: 60, _destroy: true }
      ])
    }, headers: auth_headers(legacy_tk_admin)
    expect(response).to have_http_status(:ok)
    expect(sent.reload.invoice_line_items.where(timesheet_entry_id: old_entry.id)).to be_empty

    send_request :patch, api_v1_invoice_path(sent), params: {
      invoice: invoice_fields.merge(invoice_line_items_attributes: [
        kept_attributes,
        { name: "Added", description: "added", date: Date.current.iso8601, rate: 100, quantity: 60,
          linked_timesheet_entry_ids: [new_entry.id] }
      ])
    }, headers: auth_headers(legacy_tk_admin)
    expect(response).to have_http_status(:ok)

    expect(legacy_tk_fake.entry_locked?(old_entry.id)).to be(true)
    expect(legacy_tk_fake.reservations_for(old_entry.id)).to eq([{ "invoice_id" => sent.id, "state" => "committed" }])
  end
end

RSpec.describe "Api::V1::Invoices#update under the timekeeping owner", type: :request, committed_data: true do
  let(:nested_tk_company) { create(:company, base_currency: "USD") }
  let(:nested_tk_client) { create(:client, company: nested_tk_company) }
  let(:nested_tk_admin) { create(:user, current_workspace_id: nested_tk_company.id) }
  let(:nested_tk_project) { create(:project, client: nested_tk_client, billable: true) }
  let(:nested_tk_fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  around do |example|
    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV => "http://timekeeping.test",
                         Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  before do
    create(:employment, company: nested_tk_company, user: nested_tk_admin)
    nested_tk_admin.add_role :admin, nested_tk_company
    sign_in nested_tk_admin
  end

  # "With the owner set to timekeeping, invoice saves that change an entry set call prepare, commit and abort on the fake through Timekeeping::ReservationClient, with no Net::HTTP call in specs"
  # "A nested update sends exactly one prepare to the fake"
  # Commit learns its state by replaying the identical prepare, so "one prepare" is read as one prepare
  # operation, one prepare before the first commit, and every prepare body byte-equal to the first.
  it "a nested PATCH under the timekeeping owner sends exactly one prepare to the fake, commits it, and never opens Net::HTTP" do
    entries = create_list(:timesheet_entry, 2, user: nested_tk_admin, project: nested_tk_project,
      bill_status: :unbilled, locked: false, work_date: Date.current, duration: 60)
    invoice = create(:invoice, company: nested_tk_company, client: nested_tk_client, invoice_number: "INV-TK-NESTED-001")
    TimekeepingOwnership.current.update!(owner: "timekeeping", handoff_step: nil)
    nested_tk_fake.generation = TimekeepingOwnership.current.generation
    entries.each do |entry|
      nested_tk_fake.add_entry(company_id: nested_tk_company.id, user_id: entry.user_id, project_id: entry.project_id, id: entry.id)
    end
    allow(Timekeeping::ReservationHttp).to receive(:new)
      .and_return(TimekeepingContract::FakeClient.new(timekeeping: nested_tk_fake, relay: nil))
    expect(Net::HTTP).not_to receive(:start)

    send_request :patch, api_v1_invoice_path(invoice), params: {
      invoice: {
        client_id: nested_tk_client.id,
        invoice_number: "INV-TK-NESTED-001",
        issue_date: invoice.issue_date.iso8601,
        due_date: invoice.due_date.iso8601,
        status: "draft",
        currency: nested_tk_company.base_currency,
        invoice_line_items_attributes: [
          { name: "One", description: "1", date: Date.current.iso8601, rate: 100, quantity: 60,
            timesheet_entry_id: entries.first.id },
          { name: "Two", description: "2", date: Date.current.iso8601, rate: 100, quantity: 60,
            linked_timesheet_entry_ids: [entries.second.id] }
        ]
      }
    }, headers: auth_headers(nested_tk_admin)

    expect(response).to have_http_status(:ok)
    paths = nested_tk_fake.requests.pluck(:path)
    prepares = nested_tk_fake.requests.select { |request| request[:path].end_with?("/reservations/prepare") }
    expect(prepares).not_to be_empty
    expect(prepares.map { |request| request[:body]["operation_id"] }.uniq.size).to eq(1)
    expect(prepares.pluck(:body).uniq.size).to eq(1)
    expect(prepares.first[:path]).to eq("/v1/companies/#{nested_tk_company.id}/reservations/prepare")
    expect(prepares.first[:body]["entries"]).to eq(entries.map(&:id).sort)
    expect(prepares.first[:body]["invoice_id"]).to eq(invoice.id)
    first_commit = paths.index { |path| path.end_with?("/reservations/commit") }
    expect(first_commit).not_to be_nil
    expect(paths.first(first_commit).count { |path| path.end_with?("/reservations/prepare") }).to eq(1)
    entries.each do |entry|
      expect(nested_tk_fake.reservations_for(entry.id)).to eq([{ "invoice_id" => invoice.id, "state" => "committed" }])
      expect(nested_tk_fake.entry_locked?(entry.id)).to be(true)
    end
  end
end

RSpec.describe "Api::V1::Invoices#update under the timekeeping owner, racing saves", type: :request, committed_data: true do
  let(:race_company) { create(:company) }
  let(:race_client) { create(:client, company: race_company) }
  let(:race_project) { create(:project, client: race_client, billable: true) }
  let(:race_admin) { create(:user, current_workspace_id: race_company.id) }
  let(:race_fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  around do |example|
    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV => "http://timekeeping.test",
                         Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  before do
    create(:employment, company: race_company, user: race_admin)
    race_admin.add_role :admin, race_company
    sign_in race_admin
  end

  def race_patch_entry_line(invoice, entry)
    send_request :patch, api_v1_invoice_path(invoice), params: {
      invoice: {
        client_id: race_client.id, invoice_number: invoice.invoice_number,
        issue_date: invoice.issue_date.iso8601, due_date: invoice.due_date.iso8601,
        status: "draft", currency: race_company.base_currency,
        invoice_line_items_attributes: [
          { name: "Raced", description: "raced", date: Date.current.iso8601, rate: 100, quantity: 60,
            timesheet_entry_id: entry.id }
        ]
      }
    }, headers: auth_headers(race_admin)
    [response.status, response.body]
  end

  # "Concurrent saves on separate connections over committed data converge: exactly one invoice keeps a raced entry and the other fails with \"entry is on another invoice\""
  # "The barrier commits the winner before the loser prepares."
  it "two drafts racing on one entry over separate connections leave it on exactly one invoice and refuse the other with entry is on another invoice" do
    entry = create(:timesheet_entry, user: race_admin, project: race_project, bill_status: "unbilled")
    TimekeepingOwnership.current.update!(owner: "timekeeping", handoff_step: nil)
    race_fake.generation = TimekeepingOwnership.current.generation
    race_fake.add_entry(company_id: race_company.id, user_id: entry.user_id, project_id: entry.project_id, id: entry.id)
    allow(Timekeeping::ReservationHttp).to receive(:new)
      .and_return(TimekeepingContract::FakeClient.new(timekeeping: race_fake, relay: nil))
    winner = create(:invoice, company: race_company, client: race_client)
    loser = create(:invoice, company: race_company, client: race_client)

    # The barrier: the winner's save runs on its own connection and commits before the loser prepares.
    winner_result = committed_data_thread { race_patch_entry_line(winner, entry) }.value
    loser_result = committed_data_thread { race_patch_entry_line(loser, entry) }.value

    expect(winner_result.first).to eq(200)
    expect(loser_result.first).to eq(422)
    expect(loser_result.last).to include("entry is on another invoice")
    holders = InvoiceLineItem.where(timesheet_entry_id: entry.id).distinct.pluck(:invoice_id)
    expect(holders).to eq([winner.id])
    expect(race_fake.reservations_for(entry.id)).to eq([{ "invoice_id" => winner.id, "state" => "committed" }])
    expect(race_fake.entry_locked?(entry.id)).to be(true)
  end
end

RSpec.describe DeliverInvoiceOperationJob, "abort delivery for a failed timekeeping save", committed_data: true do
  let(:lost_answer_company) { create(:company) }
  let(:lost_answer_client) { create(:client, company: lost_answer_company) }
  let(:lost_answer_user) { create(:user, current_workspace_id: lost_answer_company.id) }
  let(:lost_answer_project) { create(:project, client: lost_answer_client, billable: true) }
  let(:lost_answer_fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  around do |example|
    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV => "http://timekeeping.test",
                         Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  # "With the owner set to timekeeping, invoice saves that change an entry set call prepare, commit and abort on the fake through Timekeeping::ReservationClient, with no Net::HTTP call in specs"
  # Scenario: the service stores the save's prepare, but the answer is lost as a 503, so the
  # save fails while the service still holds a provisional reservation the abort must drop.
  it "a save whose prepare reached the service but answered 503 rolls back and its abort row settles through the client with nothing left reserved" do
    create(:employment, company: lost_answer_company, user: lost_answer_user)
    entry = create(:timesheet_entry, user: lost_answer_user, project: lost_answer_project, bill_status: "unbilled")
    TimekeepingOwnership.current.update!(owner: "timekeeping", handoff_step: nil)
    lost_answer_fake.generation = TimekeepingOwnership.current.generation
    lost_answer_fake.add_entry(company_id: lost_answer_company.id, user_id: entry.user_id,
                               project_id: entry.project_id, id: entry.id)
    fake_client = TimekeepingContract::FakeClient.new(timekeeping: lost_answer_fake, relay: nil)
    first_prepare_lost = true
    lossy_http = Object.new
    lossy_http.define_singleton_method(:call) do |method, path, headers: {}, body: nil|
      answer = fake_client.call(method, path, headers:, body:)
      if first_prepare_lost && path.end_with?("/reservations/prepare")
        first_prepare_lost = false
        next TimekeepingContract::Response.new(status: 503, body: { "reason" => "unavailable" })
      end
      answer
    end
    allow(Timekeeping::ReservationHttp).to receive(:new).and_return(lossy_http)
    draft = create(:invoice, company: lost_answer_company, client: lost_answer_client)

    expect do
      ApplicationRecord.transaction do
        create(:invoice_line_item, invoice: draft, timesheet_entry: entry, rate: 100, quantity: 60)
      end
    end.to raise_error(Invoices::OperationErrors::PrepareRetryable)

    expect(draft.reload.invoice_line_items).to be_empty
    expect(InvoiceOperationIntent.where(company_id: lost_answer_company.id, invoice_id: draft.id).pluck(:state))
      .to eq(["failed"])
    abort_row = InvoiceOperationOutboxItem.find_by!(company_id: lost_answer_company.id, invoice_id: draft.id, kind: "abort")
    described_class.perform_now(abort_row.id)

    expect(abort_row.reload.delivered_at).to be_present
    abort_requests = lost_answer_fake.requests.select { |request| request[:path].end_with?("/reservations/abort") }
    expect(abort_requests).not_to be_empty
    expect(abort_requests.map { |request| request[:body]["operation_id"] }.uniq).to eq([abort_row.operation_id])
    expect(lost_answer_fake.reservations_for(entry.id)).to eq([])
    expect(lost_answer_fake.entry_locked?(entry.id)).to be(false)
  end
end
