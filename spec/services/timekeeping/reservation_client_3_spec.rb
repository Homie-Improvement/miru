# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::ReservationClient, "a late prepare after abort" do
  around do |example|
    with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  # Acceptance bar: "A prepare that arrives after its abort reserves nothing, including a delayed copy that arrives after a conflict clears"
  it "a prepare that arrives after its abort reserves nothing" do
    fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
    company_id = fake.add_company
    user_id = fake.add_user(company_id:, role: "admin")
    project_id = fake.add_project(company_id:)
    entry_id = fake.add_entry(company_id:, user_id:, project_id:).fetch("id")
    client = described_class.new(http: TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil))
    request = Invoices::ReservationRequest.new(
      company_id:, invoice_id: 501, operation_id: SecureRandom.uuid,
      generation: fake.generation, disposition: "active", entries: [entry_id]
    )

    # The save's own prepare never reached the service; the abort is delivered first.
    expect(client.abort(request).state).to eq("aborted")

    late = client.prepare(request)

    expect(late.state).to eq("aborted")
    expect(fake.entry_locked?(entry_id)).to be(false)
    expect(fake.reservations_for(entry_id)).to eq([])
  end
end
