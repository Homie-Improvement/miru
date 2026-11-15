# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::ReservationClient, "late prepare" do
  let(:fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }
  let(:client) { described_class.new(http: TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil)) }
  let(:company_id) { fake.add_company }
  let(:entry_id) do
    user_id = fake.add_user(company_id:, role: "admin")
    fake.add_entry(company_id:, user_id:, project_id: fake.add_project(company_id:))["id"]
  end

  around do |example|
    with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  it "a prepare that arrives after its abort reserves nothing" do
    request = Invoices::ReservationRequest.new(
      company_id:, invoice_id: 501, operation_id: SecureRandom.uuid, generation: fake.generation,
      disposition: "active", entries: [entry_id]
    )

    # "`abort` replays prepare, posts abort, replays prepare again and answers that state."
    expect(client.abort(request).state).to eq("aborted")

    late = client.prepare(request)

    expect(late.state).to eq("aborted")
    expect(fake.entry_locked?(entry_id)).to be(false)
    expect(fake.reservations_for(entry_id)).to eq([])
  end
end
