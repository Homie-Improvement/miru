# frozen_string_literal: true

require "rails_helper"

RSpec.describe Invoices::OutboxDelivery, "commit settlement through the Timekeeping client" do
  around do |example|
    with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  it "with the Timekeeping client a commit row answered committed while the stored intent is failed stays undelivered with one more attempt" do
    fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
    client = Timekeeping::ReservationClient.new(http: TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil))
    company_id = fake.add_company
    user_id = fake.add_user(company_id:, role: "admin")
    entry_id = fake.add_entry(company_id:, user_id:, project_id: fake.add_project(company_id:))["id"]
    operation_id = SecureRandom.uuid
    generation = fake.generation
    request = Invoices::ReservationRequest.new(
      company_id:, invoice_id: 501, operation_id:, generation:, disposition: "active", entries: [entry_id]
    )
    expect(client.prepare(request).state).to eq("prepared")
    expect(client.commit(request).state).to eq("committed")
    InvoiceOperationIntent.create!(
      company_id:, invoice_id: 501, operation_id:, state: "failed", generation:,
      disposition: "active", desired_entry_ids: [entry_id]
    )
    row = InvoiceOperationOutboxItem.create!(
      company_id:, invoice_id: 501, operation_id:, kind: "commit",
      payload: { company_id:, invoice_id: 501, operation_id:, generation:, disposition: "active", desired_entry_ids: [entry_id] }
    )

    described_class.new(adapter_source: -> { client }).deliver(row.id)

    # "HTTP 200 alone is never success."
    # "with the Timekeeping client, a commit row answered committed while the stored intent is failed stays undelivered with attempts + 1"
    expect(row.reload.delivered_at).to be_nil
    expect(row.attempts).to eq(1)
  end
end
