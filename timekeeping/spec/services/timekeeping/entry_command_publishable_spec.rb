# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

# The relay delivers in outbox_position order, so a committed snapshot the
# projection refuses would hold back every later one. These examples show the
# entry API refuses such values before anything is written.
RSpec.describe Timekeeping::EntryCommand, "values the projection can accept" do
  include_context "timekeeping entry writes"

  let(:company) { timekeeping_arrange.company }
  let(:project) { timekeeping_arrange.project(company:) }
  let(:employee_token) { timekeeping_arrange.token_for(timekeeping_arrange.user(company:, role: "employee")) }

  def create_body(**fields)
    { "project_id" => project, "work_date" => "2026-03-02", "duration" => 60.0, "source" => "manual" }.merge(fields)
  end

  def nested_metadata(levels)
    levels.times.reduce("leaf") { |value, _| { "child" => value } }
  end

  # A projection endpoint that parses the posted text the way the monolith's
  # receiver does, with JSON's default nesting limit.
  def projection_parsing_endpoint(parsed)
    endpoint = Object.new
    endpoint.define_singleton_method(:deliver) do |batch, idempotency_key:|
      parsed << JSON.parse(TimekeepingRelay::BatchJson.generate(batch))
      TimekeepingRelay::Response.new(status: 200, body: { "applied" => batch.fetch("snapshots").size, "ignored" => 0 })
    end
    endpoint
  end

  it "refuses an agent_id that is zero or negative, as the projection does" do
    [0, -3].each do |agent_id|
      expect { build_entry_command(:create, token: employee_token, body: create_body("agent_id" => agent_id)) }
        .to raise_error(ActionController::BadRequest, /agent_id/)
    end
    expect(OutboxSnapshot.count).to eq(0)
  end

  it "refuses a negative duration, as the projection does" do
    expect { build_entry_command(:create, token: employee_token, body: create_body("duration" => -1.0)) }
      .to raise_error(ActionController::BadRequest, /duration/)
    expect(OutboxSnapshot.count).to eq(0)
  end

  it "refuses a body nested one level deeper than its snapshot could be delivered" do
    expect do
      build_entry_command(:create, token: employee_token, body: create_body("proof_metadata" => nested_metadata(97)))
    end.to raise_error(ActionController::BadRequest, /nested too deeply/)
    expect(OutboxSnapshot.count).to eq(0)
  end

  it "delivers an entry at the deepest accepted nesting through a receiver with JSON's default limit" do
    metadata = nested_metadata(96)
    command = build_entry_command(:create, token: employee_token, body: create_body("proof_metadata" => metadata))
    expect(Timekeeping::EntryWriter.new.call(command).status).to eq(201)

    parsed = []
    result = TimekeepingRelay::Relay.new(source: Timekeeping::RelayOutboxSource.new,
                                         endpoint: projection_parsing_endpoint(parsed)).deliver(limit: 10)

    expect(result).to eq(sent: 1, last_position: OutboxSnapshot.maximum(:outbox_position))
    expect(parsed.first.dig("snapshots", 0, "entry", "proof_metadata")).to eq(metadata)
    expect(OutboxSnapshot.where(sent_at: nil)).to be_empty
  end
end
