# frozen_string_literal: true

require "spec_helper"
require_relative "../../../../spec/support/timekeeping/fake_relay"

RSpec.describe TimekeepingRelay::BatchJson do
  # The consumer refuses a reused key whose body text differs, so a source that
  # rebuilds the same row with its keys in another order must still post the
  # text the key was taken from.
  it "lets a lost-mark retry of a reordered row replay the stored answer and mark it sent" do
    endpoint, _projection = TimekeepingRelaySpec::FakeRelayEndpoint.over_projection
    row = TimekeepingRelaySpec::MemoryOutboxSource.row(1, id: 77,
                                                          generation: TimekeepingContract::FakeTimekeeping::INITIAL_GENERATION)
    source = TimekeepingRelaySpec::MemoryOutboxSource.new([row])
    source.fail_next_mark!
    relay = TimekeepingRelay::Relay.new(source:, endpoint:)

    expect { relay.deliver(limit: 10) }.to raise_error(IOError)
    expect(source.lost_marks).to eq([[1]])
    row["entry"] = row.fetch("entry").to_a.reverse.to_h

    expect(relay.deliver(limit: 10)).to eq(sent: 1, last_position: 1)
    expect(endpoint.posts.map { |post| post[:answer].status }).to eq([200, 200])
    expect(source.sent_positions).to eq([1])
  end

  # An entry can be admitted with metadata nested close to JSON's default
  # limit of 100; the batch envelope must not push it past what can be sent.
  it "serializes and keys a batch whose entry metadata is nested 98 levels deep" do
    metadata = 98.times.reduce("leaf") { |value, _| { "child" => value } }
    row = { "generation" => 1, "outbox_position" => 1,
            "entry" => { "id" => 5, "company_id" => 1, "version" => 1, "proof_metadata" => metadata } }
    endpoint = TimekeepingRelaySpec::FakeRelayEndpoint.new(
      answers: [TimekeepingRelay::Response.new(status: 200, body: { "applied" => 1, "ignored" => 0 })]
    )

    result = TimekeepingRelay::Relay.new(source: TimekeepingRelaySpec::MemoryOutboxSource.new([row]), endpoint:)
                                    .deliver(limit: 10)

    expect(result).to eq(sent: 1, last_position: 1)
    posted = described_class.generate(endpoint.posts.fetch(0)[:batch])
    expect(JSON.parse(posted, max_nesting: false).dig("snapshots", 0, "entry", "proof_metadata")).to eq(metadata)
  end
end
