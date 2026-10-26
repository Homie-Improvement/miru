# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::EntryWriteRefused do
  let(:refused_company) { create(:company) }
  let(:refused_actor) { create(:user) }
  let(:refused_context) do
    Timekeeping::WriteContext.new(
      company: refused_company, actor: refused_actor, actor_kind: "user", request_id: "req-refused-1"
    )
  end

  after { Current.reset }

  it "takes its actor from the write context, not from Current, and carries only the counting fields" do
    Current.user = create(:user)

    event = assert_event_reported("Timekeeping::EntryWriteRefused") do
      Rails.event.notify(described_class.new(refused_context, reason: "stale_generation"))
    end

    payload = event[:payload]
    expect(payload.actor).to eq(refused_actor)
    expect(payload.to_h[:data]).to eq(
      reason: "stale_generation", company_id: refused_company.id, request_id: "req-refused-1", actor_kind: "user"
    )
  end

  it "rejects a reason it does not count" do
    expect { described_class.new(refused_context, reason: "other") }.to raise_error(ArgumentError, /reason/)
  end
end
