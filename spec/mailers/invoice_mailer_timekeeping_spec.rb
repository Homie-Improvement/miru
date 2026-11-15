# frozen_string_literal: true

require "rails_helper"

RSpec.describe InvoiceMailer, "remote billing under the timekeeping owner", type: :mailer do
  around do |example|
    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV => "http://timekeeping.test",
                         Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  it "under the timekeeping owner a mark-billed answer of 503 leaves the invoice unsent with sent_at nil and no mail delivered" do
    company = create(:company)
    client = create(:client, company:)
    project = create(:project, client:, billable: true)
    owner = create(:user, current_workspace_id: company.id)
    entry = create(:timesheet_entry, user: owner, project:, bill_status: "unbilled")
    invoice = create(:invoice, client:, company:, status: :sending)
    create(:invoice_line_item, invoice:, timesheet_entry: entry, rate: 100, quantity: 60)
    allow(InvoicePayment::PdfGeneration).to receive(:process).and_return("%PDF-1.4 invoice")

    fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
    fake_client = TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil)
    billing_unavailable = lambda do |method, path, headers:, body:|
      if path.end_with?("/mark-billed")
        TimekeepingContract::Response.new(status: 503, body: { "reason" => "unavailable" })
      else
        fake_client.call(method, path, headers:, body:)
      end
    end
    allow(Timekeeping::ReservationHttp).to receive(:new).and_return(billing_unavailable)
    TimekeepingOwnership.current.update!(owner: "timekeeping", handoff_step: nil)
    fake.generation = TimekeepingOwnership.current.generation

    # "Make it decide from a table: `committed` returns, `refused` raises `OperationErrors::Refused`, and every other state raises `OperationErrors::PrepareRetryable` with the reason."
    expect do
      InvoiceMailer.with(invoice_id: invoice.id, subject: "Invoice", recipients: [client.email]).invoice.deliver_now
    end.to raise_error(Invoices::OperationErrors::PrepareRetryable)

    # "So a raise rolls back `sent_at` and the sent status, and no mail goes out."
    invoice.reload
    expect(invoice.sent_at).to be_nil
    expect(invoice.status).to eq("sending")
    expect(ActionMailer::Base.deliveries).to be_empty
    expect(fake.requests.count { |sent| sent[:path].end_with?("/invoices/#{invoice.id}/mark-billed") }).to eq(0)
  end
end

# The intent and outbox rows commit on their own connection, so this runs on committed data.
RSpec.describe InvoiceMailer, "sending before the commit reaches the timekeeping service", type: :mailer,
                                                                                           committed_data: true do
  around do |example|
    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV => "http://timekeeping.test",
                         Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  it "refuses to send while the invoice's commit is undelivered, then bills the entry and sends once the commit is redelivered" do
    company = create(:company)
    client = create(:client, company:)
    project = create(:project, client:, billable: true)
    owner = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user: owner)
    entry = create(:timesheet_entry, user: owner, project:, bill_status: "unbilled")
    allow(InvoicePayment::PdfGeneration).to receive(:process).and_return("%PDF-1.4 invoice")
    TimekeepingOwnership.current.update!(owner: "timekeeping", handoff_step: nil)
    fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
    fake.generation = TimekeepingOwnership.current.generation
    fake.add_entry(company_id: company.id, user_id: entry.user_id, project_id: entry.project_id, id: entry.id)
    fake_client = TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil)
    commit_unavailable = true
    flaky_http = Object.new
    flaky_http.define_singleton_method(:call) do |method, path, headers: {}, body: nil|
      if commit_unavailable && path.end_with?("/reservations/commit")
        next TimekeepingContract::Response.new(status: 503, body: { "reason" => "unavailable" })
      end

      fake_client.call(method, path, headers:, body:)
    end
    allow(Timekeeping::ReservationHttp).to receive(:new).and_return(flaky_http)
    # Only a draft gaining an entry reserves it, so the line goes on a draft that is then queued for sending.
    invoice = create(:invoice, client:, company:)
    create(:invoice_line_item, invoice:, timesheet_entry: entry, rate: 100, quantity: 60)
    invoice.update_columns(status: "sending")
    commit_row = InvoiceOperationOutboxItem.find_by!(company_id: company.id, invoice_id: invoice.id, kind: "commit")
    expect(commit_row.delivered_at).to be_nil
    send_invoice = -> {
      InvoiceMailer.with(invoice_id: invoice.id, subject: "Invoice", recipients: [client.email]).invoice.deliver_now
    }

    expect(&send_invoice).to raise_error(Invoices::OperationErrors::PrepareRetryable, "commit_undelivered")

    expect(invoice.reload.sent_at).to be_nil
    expect(invoice.status).to eq("sending")
    expect(ActionMailer::Base.deliveries).to be_empty
    expect(fake.requests.count { |sent| sent[:path].end_with?("/mark-billed") }).to eq(0)

    commit_unavailable = false
    DeliverInvoiceOperationJob.perform_now(commit_row.id)
    expect(commit_row.reload.delivered_at).to be_present

    send_invoice.call

    expect(invoice.reload.status).to eq("sent")
    expect(invoice.sent_at).to be_present
    expect(ActionMailer::Base.deliveries.size).to eq(1)
    expect(fake.stored_entry(entry.id)["bill_status"]).to eq("billed")
  end
end
