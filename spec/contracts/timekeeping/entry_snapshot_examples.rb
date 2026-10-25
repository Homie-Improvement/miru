# frozen_string_literal: true

require "json"
require_relative "contract_example_helpers"

# The entry snapshot event (contracts/timekeeping/entry_snapshots.yml), as two
# groups: what a producer publishes, and what the projection endpoint does
# with it. Both need the timekeeping_client and timekeeping_arrange lets.
RSpec.shared_examples "timekeeping entry snapshot shape" do
  include TimekeepingContractExampleHelpers

  let(:snapshot_contract) { TimekeepingContract.load(:entry_snapshots) }
  let(:company) { timekeeping_arrange.company }
  let(:user) { timekeeping_arrange.user(company:, role: "owner") }
  let(:project) { timekeeping_arrange.project(company:) }

  def snapshots_for(entry_id)
    timekeeping_arrange.published_snapshots.fetch("snapshots").select { |item| item.dig("entry", "id") == entry_id }
  end

  it "publishes exactly the batch, item and entry keys of the contract, so no name or email can travel" do
    entry_id = timekeeping_arrange.entry(company:, user:, project:, proof_metadata: { "run" => "nightly" })

    batch = timekeeping_arrange.published_snapshots

    expect(batch.keys).to match_array(snapshot_contract.fetch("batch_fields"))
    expect(batch.fetch("schema_version")).to eq(snapshot_contract.fetch("schema_version"))
    batch.fetch("snapshots").each do |item|
      expect(item.keys).to match_array(snapshot_contract.fetch("item_fields"))
      expect(item.fetch("entry").keys).to match_array(snapshot_contract.fetch("entry_fields"))
    end
    expect(snapshots_for(entry_id).last.fetch("entry")).to include(
      "id" => entry_id, "company_id" => company, "user_id" => user, "project_id" => project, "proof_metadata" => { "run" => "nightly" }
    )
  end

  it "carries no credential anywhere in the batch, nested metadata included" do
    token = timekeeping_arrange.token_for(user)
    relay_identity = timekeeping_arrange.service_identity(company: nil, name: "timekeeping", operations: ["deliver"])
    timekeeping_arrange.entry(company:, user:, project:)

    serialized = JSON.generate(timekeeping_arrange.published_snapshots)

    expect(serialized).not_to include(token)
    expect(serialized).not_to include(relay_identity)
  end

  it "keeps duration as the unconverted float" do
    entry_id = timekeeping_arrange.entry(company:, user:, project:, duration: 90.0)

    expect(snapshots_for(entry_id).last.dig("entry", "duration")).to eql(90.0)
  end

  it "publishes locked true once the entry has a reservation, with a higher version" do
    entry_id = timekeeping_arrange.reserved_entry(company:, invoice_id: 501)

    versions = snapshots_for(entry_id).map { |item| item.dig("entry", "version") }

    expect(snapshots_for(entry_id).last.dig("entry", "locked")).to be(true)
    expect(versions).to eq(versions.sort.uniq)
  end

  it "publishes in rising outbox_position order under the current generation" do
    2.times { timekeeping_arrange.entry(company:, user:, project:) }

    items = timekeeping_arrange.published_snapshots.fetch("snapshots")
    positions = items.map { |item| item.fetch("outbox_position") }

    expect(positions.size).to be >= 2
    expect(positions).to eq(positions.sort.uniq)
    expect(items.map { |item| item.fetch("generation") }.uniq).to eq([timekeeping_arrange.current_generation])
  end
end

RSpec.shared_examples "timekeeping entry snapshot endpoint" do
  include TimekeepingContractExampleHelpers

  let(:company) { timekeeping_arrange.company }
  let(:relay_identity) { timekeeping_arrange.service_identity(company: nil, name: "timekeeping", operations: ["deliver"]) }
  let(:entry_id) { 70_001 }
  let(:stale_generation) { timekeeping_contract_error(:entry_snapshots, "stale_generation") }

  def deliver(*items, key: nil, credential: relay_identity)
    deliver_snapshots(credential, items, key:)
  end

  it "upserts by version: v2, then v1, then v2 again leaves v2" do
    expect(deliver(snapshot_item(entry_id:, company:, version: 2)).body).to eq("applied" => 1, "ignored" => 0)
    expect(deliver(snapshot_item(entry_id:, company:, version: 1)).body).to eq("applied" => 0, "ignored" => 1)
    expect(timekeeping_arrange.projected_entry(entry_id)).to include("version" => 2, "note" => "v2")
    expect(deliver(snapshot_item(entry_id:, company:, version: 2)).body).to eq("applied" => 0, "ignored" => 1)
    expect(timekeeping_arrange.projected_entry(entry_id)).to include("version" => 2, "note" => "v2")
  end

  it "keeps a tombstone: v3 discarded, then a late v2, leaves the entry discarded" do
    deliver(snapshot_item(entry_id:, company:, version: 3, discarded_at: "2026-03-03T10:00:00Z"))

    late = deliver(snapshot_item(entry_id:, company:, version: 2))

    expect(late.body).to eq("applied" => 0, "ignored" => 1)
    expect(timekeeping_arrange.projected_entry(entry_id)).to include("version" => 3, "discarded_at" => "2026-03-03T10:00:00Z")
  end

  it "keeps duration as the unconverted float and company_id on the projected row" do
    deliver(snapshot_item(entry_id:, company:, version: 1, duration: 90.0))

    expect(timekeeping_arrange.projected_entry(entry_id).fetch("duration")).to eql(90.0)
    expect(timekeeping_arrange.projected_entry(entry_id).fetch("company_id")).to eq(company)
  end

  it "refuses a previous-generation snapshot after the flip and leaves the row unchanged" do
    timekeeping_arrange.set_generation(2)
    deliver(snapshot_item(entry_id:, company:, version: 1, generation: 2))
    timekeeping_arrange.begin_handoff(previous_generation: 1, final_outbox_position: 10)
    timekeeping_arrange.flip_ownership

    response = deliver(snapshot_item(entry_id:, company:, version: 5, generation: 1, outbox_position: 5))

    expect([response.status, response.body]).to eq([stale_generation.fetch("status"), stale_generation.fetch("body")])
    expect(timekeeping_arrange.projected_entry(entry_id)).to include("version" => 1)
  end

  it "accepts the previous generation during the handoff only up to the final outbox position" do
    timekeeping_arrange.set_generation(2)
    timekeeping_arrange.begin_handoff(previous_generation: 1, final_outbox_position: 10)

    at_final = deliver(snapshot_item(entry_id:, company:, version: 1, generation: 1, outbox_position: 10))
    past_final = deliver(snapshot_item(entry_id:, company:, version: 2, generation: 1, outbox_position: 11))

    expect(at_final.body).to eq("applied" => 1, "ignored" => 0)
    expect([past_final.status, past_final.body]).to eq([stale_generation.fetch("status"), stale_generation.fetch("body")])
    expect(timekeeping_arrange.projected_entry(entry_id)).to include("version" => 1)
  end

  it "applies nothing from a batch that holds one stale snapshot" do
    timekeeping_arrange.set_generation(2)
    other_entry = entry_id + 1

    response = deliver(snapshot_item(entry_id:, company:, version: 1, generation: 2),
                       snapshot_item(entry_id: other_entry, company:, version: 1, generation: 1))

    expect(response.status).to eq(stale_generation.fetch("status"))
    expect(timekeeping_arrange.projected_entry(entry_id)).to be_nil
    expect(timekeeping_arrange.projected_entry(other_entry)).to be_nil
  end

  it "refuses a caller without the Timekeeping service identity and applies nothing" do
    user_token = timekeeping_arrange.token_for(timekeeping_arrange.user(company:, role: "owner"))
    other_service = timekeeping_arrange.service_identity(company:, name: "reporting", operations: [])
    item = snapshot_item(entry_id:, company:, version: 1)

    expect(deliver(item, credential: nil).status).to eq(timekeeping_contract_error(:entry_snapshots, "unauthorized").fetch("status"))
    expect(deliver(item, credential: user_token).status).to eq(timekeeping_contract_error(:entry_snapshots, "forbidden").fetch("status"))
    expect(deliver(item, credential: other_service).status).to eq(timekeeping_contract_error(:entry_snapshots, "forbidden").fetch("status"))
    expect(timekeeping_arrange.projected_entry(entry_id)).to be_nil
  end
end
