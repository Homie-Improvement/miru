# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

# An agent create and a detach-entries of the same agent, each on its own
# connection, with one held at a named step while the other runs, so the two
# meet at a known point instead of depending on thread timing.
RSpec.describe Timekeeping::EntryWriter, "agent create ordered against a detach of the agent" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  let(:wait_seconds) { 10 }
  let(:company) { timekeeping_arrange.company }
  let(:project) { timekeeping_arrange.project(company:) }
  let(:owner) { timekeeping_arrange.user(company:, role: "owner") }
  let(:agent) { timekeeping_arrange.agent(company:, user: owner) }

  def agent_create
    build_entry_command(:create, token: timekeeping_arrange.token_for(owner), body: {
                          "project_id" => project, "work_date" => "2026-03-02", "duration" => 60.0,
                          "note" => "Agent create", "source" => "automation", "source_metadata" => {},
                          "agent_id" => agent
                        })
  end

  def detach_request
    Timekeeping::ServiceCommands::Request.new(
      route: :detach_entries, company_id: company, actor_name: "agent-boundary", target_id: agent,
      operation_id: SecureRandom.uuid, generation: timekeeping_arrange.current_generation
    )
  end

  def on_own_connection(&block)
    Thread.new { ApplicationRecord.connection_pool.with_connection { block.call } }
  end

  # Runs the create until it reaches hold_at, then starts the detach on
  # another connection and lets the create go on after detach_wait seconds.
  # Returns the create's outcome, the detach's outcome and whether the detach
  # finished while the create was held.
  def run_create_held_at(hold_at, detach_wait:)
    command = agent_create
    request = detach_request
    reached = Queue.new
    release = Queue.new
    checkpoint = lambda do |step|
      next unless step == hold_at

      reached << true
      release.pop
    end
    creator = on_own_connection { described_class.new(checkpoint:).call(command) }
    detacher = nil
    detach_finished_while_held = false
    begin
      expect(reached.pop(timeout: wait_seconds)).to be(true)
      detacher = on_own_connection { Timekeeping::ServiceCommands.new.call(request) }
      detach_finished_while_held = !detacher.join(detach_wait).nil?
    ensure
      release << true
    end
    [creator.join(wait_seconds)&.value, detacher&.join(wait_seconds)&.value, detach_finished_while_held]
  end

  it "makes a detach wait for a create that holds the agent lock, then detaches the committed entry" do
    created, detached, detach_finished_while_held = run_create_held_at(:generation_checked, detach_wait: 1)

    expect(detach_finished_while_held).to be(false)
    expect(created.status).to eq(201)
    expect([detached.status, JSON.parse(detached.body)]).to eq([200, { "detached" => 1 }])
    expect(Entry.sole.agent_id).to be_nil
  end

  it "refuses a create held before the agent lock once a detach of the agent committed meanwhile" do
    created, detached, detach_finished_while_held = run_create_held_at(:receipt_checked, detach_wait: wait_seconds)

    expect(detach_finished_while_held).to be(true)
    expect([detached.status, JSON.parse(detached.body)]).to eq([200, { "detached" => 0 }])
    expect([created.status, JSON.parse(created.body)]).to eq([404, { "reason" => "not_found" }])
    expect(Entry.count).to eq(0)
  end
end
