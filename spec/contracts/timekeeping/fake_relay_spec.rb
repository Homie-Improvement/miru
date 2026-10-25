# frozen_string_literal: true

require "rails_helper"
require_relative "entry_snapshot_examples"
require_relative "idempotency_examples"

RSpec.describe TimekeepingContract::FakeRelay do
  include_context "timekeeping contract fakes"

  describe "the snapshot shape published from the fake Timekeeping" do
    it_behaves_like "timekeeping entry snapshot shape"
  end

  describe "the snapshot endpoint" do
    it_behaves_like "timekeeping entry snapshot endpoint"
  end

  describe "the idempotency contract for snapshot deliveries" do
    it_behaves_like "timekeeping idempotency contract", contracts: [:entry_snapshots]
  end

  describe "#deliver_pending" do
    let(:relay_identity) { timekeeping_arrange.service_identity(company: nil, name: "timekeeping", operations: ["deliver"]) }

    it "carries the outbox into the projection and sends each row once after a 200" do
      company = timekeeping_arrange.company
      user = timekeeping_arrange.user(company:, role: "owner")
      entry_id = timekeeping_arrange.entry(company:, user:, project: timekeeping_arrange.project(company:), duration: 90.0)

      first = fake_relay.deliver_pending(credential: relay_identity, idempotency_key: SecureRandom.uuid)

      expect(first.body).to eq("applied" => 1, "ignored" => 0)
      expect(fake_relay.projected_entry(entry_id)).to include("id" => entry_id, "company_id" => company, "duration" => 90.0)
      expect(fake_relay.next_batch.fetch("snapshots")).to be_empty
    end

    it "keeps the rows unsent when the endpoint refuses the batch" do
      company = timekeeping_arrange.company
      user = timekeeping_arrange.user(company:, role: "owner")
      timekeeping_arrange.entry(company:, user:, project: timekeeping_arrange.project(company:))

      refused = fake_relay.deliver_pending(credential: nil, idempotency_key: SecureRandom.uuid)

      expect(refused.status).to eq(401)
      expect(fake_relay.next_batch.fetch("snapshots").size).to eq(1)
    end
  end
end
