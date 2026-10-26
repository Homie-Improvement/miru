# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::WriteContext do
  let(:write_context_company) { create(:company) }
  let(:write_context_actor) { create(:user) }

  it "holds the company, actor, actor kind and request id, with no agent by default" do
    context = described_class.new(
      company: write_context_company, actor: write_context_actor, actor_kind: "user", request_id: "req-ctx-1"
    )

    expect(context.company).to eq(write_context_company)
    expect(context.actor).to eq(write_context_actor)
    expect(context.actor_kind).to eq("user")
    expect(context.request_id).to eq("req-ctx-1")
    expect(context.agent).to be_nil
  end

  it "rejects an actor kind it does not know" do
    expect do
      described_class.new(company: write_context_company, actor: write_context_actor, actor_kind: "robot", request_id: "r")
    end.to raise_error(ArgumentError, /actor_kind/)
  end
end
