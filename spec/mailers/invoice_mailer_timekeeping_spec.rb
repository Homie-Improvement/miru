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
