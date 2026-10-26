# frozen_string_literal: true

require "yaml"

# The gem keeps its own copies of the snapshot contract's values, because it
# is used without the contracts directory. These examples hold the copies to
# contracts/timekeeping/entry_snapshots.yml.
RSpec.describe "TimekeepingRelay against contracts/timekeeping/entry_snapshots.yml" do
  let(:contract) { YAML.load_file(File.expand_path("../../../../contracts/timekeeping/entry_snapshots.yml", __dir__)) }

  it "sends the contract's schema_version" do
    expect(TimekeepingRelay::Relay::SCHEMA_VERSION).to eq(contract.fetch("schema_version"))
  end

  it "posts to the contract's deliver route" do
    route = contract.dig("routes", "deliver")

    expect(route.fetch("method")).to eq("POST")
    expect(TimekeepingRelay::HttpEndpoint::DELIVER_PATH).to eq(route.fetch("path"))
  end

  it "builds batches with exactly the contract's batch and item keys" do
    endpoint = TimekeepingRelaySpec::FakeRelayEndpoint.new(
      answers: [TimekeepingRelay::Response.new(status: 200, body: { "applied" => 1, "ignored" => 0 })]
    )
    source = TimekeepingRelaySpec::MemoryOutboxSource.new([TimekeepingRelaySpec::MemoryOutboxSource.row(1)])

    TimekeepingRelay::Relay.new(source:, endpoint:).deliver(limit: 10)
    batch = endpoint.posts.fetch(0)[:batch]

    expect(batch.keys).to match_array(contract.fetch("batch_fields"))
    expect(batch.fetch("snapshots").first.keys).to match_array(contract.fetch("item_fields"))
  end

  it "knows exactly the contract's error answers, each by its status" do
    contract_errors = contract.fetch("errors").to_h do |name, error|
      [error.fetch("status"), error.dig("body", "reason")].tap { |(_, reason)| expect(reason).to eq(name) }
    end

    expect(TimekeepingRelay::FailureReason::KNOWN_REASONS).to eq(contract_errors)
  end
end
