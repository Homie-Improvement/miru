# frozen_string_literal: true

require "rails_helper"

RSpec.describe Invoices::OutboxDelivery, "lost commit answers from the Timekeeping service" do
  around do |example|
    with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  it "a lost commit answer is redelivered and applies once" do
    fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
    commit_calls = 0
    # Only the first commit's answer is lost; the fake still applies it.
    dropping = TimekeepingContract::DroppingHttp.new(
      TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil),
      drop: ->(_method, path) { path.end_with?("/reservations/commit") && (commit_calls += 1) == 1 }
    )
    client = Timekeeping::ReservationClient.new(http: dropping)
    company_id = fake.add_company
    user_id = fake.add_user(company_id:, role: "admin")
    entry_id = fake.add_entry(company_id:, user_id:, project_id: fake.add_project(company_id:))["id"]
    operation_id = SecureRandom.uuid
    generation = fake.generation
    request = Invoices::ReservationRequest.new(
      company_id:, invoice_id: 504, operation_id:, generation:, disposition: "active", entries: [entry_id]
    )
    expect(client.prepare(request).state).to eq("prepared")
    InvoiceOperationIntent.create!(
      company_id:, invoice_id: 504, operation_id:, state: "committed", generation:,
      disposition: "active", desired_entry_ids: [entry_id]
    )
    row = InvoiceOperationOutboxItem.create!(
      company_id:, invoice_id: 504, operation_id:, kind: "commit",
      payload: { company_id:, invoice_id: 504, operation_id:, generation:, disposition: "active", desired_entry_ids: [entry_id] }
    )
    delivery = Invoices::OutboxDelivery.new(adapter_source: -> { client })

    delivery.deliver(row.id)

    # The fake applied the dropped commit, but the row cannot know it and stays for redelivery.
    after_first = fake.reservations_for(entry_id)
    expect(after_first).to eq([{ "invoice_id" => 504, "state" => "committed" }])
    expect(row.reload.delivered_at).to be_nil
    expect(row.undeliverable_at).to be_nil
    expect(row.attempts).to eq(1)

    delivery.deliver(row.id)

    # "a lost commit answer is redelivered and applies once"
    expect(row.reload.delivered_at).to be_present
    commit_bodies = fake.requests.filter_map { |logged| logged[:body] if logged[:path].end_with?("/reservations/commit") }
    expect(commit_bodies.size).to eq(2)
    expect(commit_bodies.uniq.size).to eq(1)
    expect(fake.reservations_for(entry_id)).to eq(after_first)
    expect(fake.entry_locked?(entry_id)).to be(true)
  end
end
