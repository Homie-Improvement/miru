# frozen_string_literal: true

require_relative "contract_example_helpers"

# Replay-only deletes (contracts/timekeeping/entry_api.yml rules.replay_only):
# a DELETE or bulk delete carrying Idempotency-Replay: only is answered from
# the caller's own stored receipt, read before the generation check, and
# otherwise answers not_found without discarding anything. Needs the timekeeping_client and
# timekeeping_arrange lets. Kept apart from the idempotency group because the
# local owner, which also runs that group, does not serve replay-only deletes.
RSpec.shared_examples "timekeeping entry replay contract" do
  include TimekeepingContractExampleHelpers

  let(:replay_company) { timekeeping_arrange.company }
  let(:replay_project) { timekeeping_arrange.project(company: replay_company) }
  let(:replay_owner) { timekeeping_arrange.user(company: replay_company, role: "owner") }
  let(:replay_owner_token) { timekeeping_arrange.token_for(replay_owner) }
  let(:replay_not_found) { timekeeping_contract_error(:entry_api, "not_found") }

  def replay_entry_path(entry_id)
    timekeeping_path(:entry_api, :destroy, company_id: replay_company, entry_id:)
  end

  def replay_delete(entry_id, token, key:, generation: timekeeping_arrange.current_generation)
    timekeeping_request("DELETE", replay_entry_path(entry_id), headers: user_headers(token, generation:, key:))
  end

  def replay_only_delete(entry_id, token, key:, generation: timekeeping_arrange.current_generation)
    headers = user_headers(token, generation:, key:).merge("Idempotency-Replay" => "only", "If-Match" => "replay-only")
    timekeeping_request("DELETE", replay_entry_path(entry_id), headers:)
  end

  def replay_listed_ids
    list_entries(replay_company, replay_owner_token).body.fetch("entries").map { |entry| entry.fetch("id") }
  end

  # The stored entry and the outbox size, read through the arrange object so a
  # replay can be shown to have written nothing on either provider.
  def replay_stored_state(entry_id)
    { entry: timekeeping_arrange.stored_entry(entry_id), outbox_size: timekeeping_arrange.outbox_size }
  end

  def replay_bulk_delete_path
    timekeeping_path(:entry_api, :bulk_delete, company_id: replay_company)
  end

  def replay_bulk_delete(entry_ids, token, key:, generation: timekeeping_arrange.current_generation)
    timekeeping_request("POST", replay_bulk_delete_path, headers: user_headers(token, generation:, key:),
                                                         body: { "entry_ids" => entry_ids })
  end

  # The replay sends a generation that is never an integer, so a provider
  # that does not read Idempotency-Replay refuses it as stale_generation
  # instead of deleting (entry_api.yml rules.replay_only).
  def replay_only_bulk_delete(entry_ids, token, key:)
    headers = user_headers(token, generation: "replay-only", key:).merge("Idempotency-Replay" => "only")
    timekeeping_request("POST", replay_bulk_delete_path, headers:, body: { "entry_ids" => entry_ids })
  end

  def replay_bulk_stored_state(entry_ids)
    { entries: entry_ids.map { |entry_id| timekeeping_arrange.stored_entry(entry_id) },
      outbox_size: timekeeping_arrange.outbox_size }
  end

  def replay_bulk_entries
    Array.new(2) { timekeeping_arrange.entry(company: replay_company, user: replay_owner, project: replay_project) }
  end

  it "returns the first bulk delete's answer for a replay-only bulk delete with the same key and ids, writing nothing" do
    entry_ids = replay_bulk_entries.sort
    key = new_key
    first = replay_bulk_delete(entry_ids, replay_owner_token, key:)
    after_first = replay_bulk_stored_state(entry_ids)

    replay = replay_only_bulk_delete(entry_ids, replay_owner_token, key:)

    expect(first.status).to eq(200)
    expect(first.body.fetch("results").pluck("result")).to eq(%w[deleted deleted])
    expect([replay.status, replay.body]).to eq([first.status, first.body])
    expect(replay_bulk_stored_state(entry_ids)).to eq(after_first)
  end

  it "answers a replay-only bulk delete with no stored answer as not_found and keeps every entry" do
    entry_ids = replay_bulk_entries.sort
    seeded = replay_bulk_stored_state(entry_ids)

    response = replay_only_bulk_delete(entry_ids, replay_owner_token, key: new_key)

    expect([response.status, response.body]).to eq([replay_not_found.fetch("status"), replay_not_found.fetch("body")])
    expect(replay_bulk_stored_state(entry_ids)).to eq(seeded)
    expect(replay_listed_ids).to match_array(entry_ids)
  end

  it "replays a stored bulk delete answer after the generation has advanced" do
    entry_ids = replay_bulk_entries.sort
    key = new_key
    first_generation = timekeeping_arrange.current_generation
    first = replay_bulk_delete(entry_ids, replay_owner_token, key:, generation: first_generation)
    after_first = replay_bulk_stored_state(entry_ids)
    timekeeping_arrange.set_generation(first_generation + 1)

    replay = replay_only_bulk_delete(entry_ids, replay_owner_token, key:)

    expect(first.status).to eq(200)
    expect([replay.status, replay.body]).to eq([first.status, first.body])
    expect(replay_bulk_stored_state(entry_ids)).to eq(after_first)
  end

  it "does not replay another actor's stored bulk delete under the same key" do
    entry_ids = replay_bulk_entries.sort
    key = new_key
    replay_bulk_delete(entry_ids, replay_owner_token, key:)
    other_owner = timekeeping_arrange.user(company: replay_company, role: "owner")
    after_first = replay_bulk_stored_state(entry_ids)

    response = replay_only_bulk_delete(entry_ids, timekeeping_arrange.token_for(other_owner), key:)

    expect([response.status, response.body]).to eq([replay_not_found.fetch("status"), replay_not_found.fetch("body")])
    expect(replay_bulk_stored_state(entry_ids)).to eq(after_first)
  end

  it "refuses a bulk delete whose generation is replay-only, without the replay header, as stale_generation" do
    entry_ids = replay_bulk_entries.sort
    seeded = replay_bulk_stored_state(entry_ids)
    headers = user_headers(replay_owner_token, generation: "replay-only", key: new_key)

    response = timekeeping_request("POST", replay_bulk_delete_path, headers:, body: { "entry_ids" => entry_ids })

    stale = timekeeping_contract_error(:entry_api, "stale_generation")
    expect([response.status, response.body]).to eq([stale.fetch("status"), stale.fetch("body")])
    expect(replay_bulk_stored_state(entry_ids)).to eq(seeded)
    expect(replay_listed_ids).to match_array(entry_ids)
  end

  it "returns the first delete's answer for a replay-only DELETE with the same key, and GET still answers not_found" do
    entry_id = timekeeping_arrange.entry(company: replay_company, user: replay_owner, project: replay_project)
    key = new_key
    first = replay_delete(entry_id, replay_owner_token, key:)
    after_first = replay_stored_state(entry_id)

    replay = replay_only_delete(entry_id, replay_owner_token, key:)

    expect(first.status).to eq(200)
    expect([replay.status, replay.body]).to eq([first.status, first.body])
    expect(replay_stored_state(entry_id)).to eq(after_first)
    expect(show_entry(replay_company, replay_owner_token, entry_id).status).to eq(replay_not_found.fetch("status"))
  end

  it "answers a replay-only DELETE with no stored answer as not_found and keeps the entry" do
    entry_id = timekeeping_arrange.entry(company: replay_company, user: replay_owner, project: replay_project)
    seeded = replay_stored_state(entry_id)
    expect(seeded[:entry].fetch("id")).to eq(entry_id)

    response = replay_only_delete(entry_id, replay_owner_token, key: new_key)

    expect([response.status, response.body]).to eq([replay_not_found.fetch("status"), replay_not_found.fetch("body")])
    expect(replay_stored_state(entry_id)).to eq(seeded)
    expect(replay_listed_ids).to eq([entry_id])
  end

  it "replays the stored answer after the generation has advanced" do
    entry_id = timekeeping_arrange.entry(company: replay_company, user: replay_owner, project: replay_project)
    key = new_key
    first_generation = timekeeping_arrange.current_generation
    first = replay_delete(entry_id, replay_owner_token, key:, generation: first_generation)
    after_first = replay_stored_state(entry_id)
    timekeeping_arrange.set_generation(first_generation + 1)

    replay = replay_only_delete(entry_id, replay_owner_token, key:, generation: first_generation)

    expect(first.status).to eq(200)
    expect([replay.status, replay.body]).to eq([first.status, first.body])
    expect(replay_stored_state(entry_id)).to eq(after_first)
  end

  it "does not replay another actor's stored delete under the same key" do
    entry_id = timekeeping_arrange.entry(company: replay_company, user: replay_owner, project: replay_project)
    key = new_key
    replay_delete(entry_id, replay_owner_token, key:)
    other_owner = timekeeping_arrange.user(company: replay_company, role: "owner")
    after_first = replay_stored_state(entry_id)

    response = replay_only_delete(entry_id, timekeeping_arrange.token_for(other_owner), key:)

    expect([response.status, response.body]).to eq([replay_not_found.fetch("status"), replay_not_found.fetch("body")])
    expect(replay_stored_state(entry_id)).to eq(after_first)
  end
end
