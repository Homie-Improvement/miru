# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Entry write routes: bulk delete naming only another company's entries" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "bulk_move and bulk_delete naming only another company's entries store no receipt and change nothing, pinned by request specs"
  # A foreign id and a missing id must get the same answer and the same (absent) receipt, so a caller
  # cannot learn from the answer, or from how a retry is answered, that the id belongs to another company.
  it "answers a bulk delete naming only another company's entry exactly as one naming an id that exists nowhere, storing no receipt for either" do
    arrange = timekeeping_arrange
    company = arrange.company
    other_company = arrange.company
    owner_token = arrange.token_for(arrange.user(company:, role: "owner"))
    arrange.entry(company:, user: arrange.user(company:, role: "employee"), project: arrange.project(company:))
    foreign_entry = arrange.entry(company: other_company, user: arrange.user(company: other_company, role: "employee"),
                                  project: arrange.project(company: other_company))
    missing_entry = Entry.maximum(:id) + 1000
    before = entry_write_counts
    expect(before).to include(entries: 2, idempotency_receipts: 0)

    send_bulk_delete = lambda do |entry_id, key, replay_only: false|
      headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{owner_token}",
                  "Idempotency-Key" => key, "Ownership-Generation" => arrange.current_generation.to_s }
      headers["Idempotency-Replay"] = "only" if replay_only
      post "/v1/companies/#{company}/entries/bulk-delete", params: JSON.generate("entry_ids" => [entry_id]), headers: headers
      [response.status, response.parsed_body]
    end

    foreign_key = SecureRandom.uuid
    missing_key = SecureRandom.uuid
    foreign = send_bulk_delete.call(foreign_entry, foreign_key)
    missing = send_bulk_delete.call(missing_entry, missing_key)

    expect(foreign).to eq([200, { "results" => [{ "entry_id" => foreign_entry, "result" => "not_found" }] }])
    expect(missing).to eq([200, { "results" => [{ "entry_id" => missing_entry, "result" => "not_found" }] }])
    expect(IdempotencyReceipt.where(company_id: [company, other_company]).count).to eq(0)
    expect(Entry.find(foreign_entry).discarded_at).to be_nil
    expect(entry_write_counts).to eq(before)

    # With nothing stored, a replay-only retry of either key is answered from nothing, and the two stay alike.
    foreign_replay = send_bulk_delete.call(foreign_entry, foreign_key, replay_only: true)
    missing_replay = send_bulk_delete.call(missing_entry, missing_key, replay_only: true)
    expect(foreign_replay).to eq([404, { "reason" => "not_found" }])
    expect(missing_replay).to eq(foreign_replay)
    expect(entry_write_counts).to eq(before)
  end
end


RSpec.describe "Entry write routes: bulk move naming only another company's entries" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "bulk_move and bulk_delete naming only another company's entries store no receipt and change nothing, pinned by request specs"
  # The cross-tenant guard: a request carrying another company's entry id "returns `404` or no match and changes nothing in either database, in both directions".
  it "answers a bulk move naming only another company's entry with not_found, in both directions, and stores no receipt in either company" do
    arrange = timekeeping_arrange
    company_a = arrange.company
    company_b = arrange.company
    sides = [company_a, company_b].to_h do |company|
      project = arrange.project(company:)
      target_project = arrange.project(company:)
      entry = arrange.entry(company:, user: arrange.user(company:, role: "employee"), project:)
      [company, { token: arrange.token_for(arrange.user(company:, role: "owner")), project:, target_project:, entry: }]
    end
    before = entry_write_counts
    expect(before).to include(entries: 2, idempotency_receipts: 0)
    stored_entries = Entry.order(:id).map(&:attributes)

    [[company_a, company_b], [company_b, company_a]].each do |requester, owner|
      foreign_entry = sides.fetch(owner).fetch(:entry)
      headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{sides.fetch(requester).fetch(:token)}",
                  "Idempotency-Key" => SecureRandom.uuid, "Ownership-Generation" => arrange.current_generation.to_s }
      body = { "entry_ids" => [foreign_entry], "project_id" => sides.fetch(requester).fetch(:target_project) }

      post "/v1/companies/#{requester}/entries/bulk-move", params: JSON.generate(body), headers: headers

      expect([response.status, response.parsed_body])
        .to eq([200, { "results" => [{ "entry_id" => foreign_entry, "result" => "not_found" }] }])
      expect(IdempotencyReceipt.where(company_id: requester).count).to eq(0), "receipt stored for #{requester}"
      expect(IdempotencyReceipt.where(company_id: owner).count).to eq(0)
    end

    expect(entry_write_counts).to eq(before)
    expect(Entry.order(:id).map(&:attributes)).to eq(stored_entries)
  end
end


RSpec.describe "Entry write routes: bulk delete naming only another company's entries, in both directions" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "bulk_move and bulk_delete naming only another company's entries store no receipt and change nothing, pinned by request specs"
  # "A request that changes nothing stores no receipt, and a retry of it is evaluated again."
  it "stores no receipt and changes nothing for a bulk delete naming only another company's entry, in both directions, and evaluates its retry again" do
    arrange = timekeeping_arrange
    companies = [arrange.company, arrange.company]
    owners = companies.map { |company| arrange.user(company:, role: "owner") }
    entries = companies.map do |company|
      arrange.entry(company:, user: arrange.user(company:, role: "employee"), project: arrange.project(company:))
    end
    send_bulk_delete = lambda do |requester, entry_ids, key, extra_headers = {}|
      headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{arrange.token_for(owners[requester])}",
                  "Idempotency-Key" => key, "Ownership-Generation" => arrange.current_generation.to_s }.merge(extra_headers)
      post "/v1/companies/#{companies[requester]}/entries/bulk-delete", params: JSON.generate("entry_ids" => entry_ids),
                                                                        headers: headers
      [response.status, response.parsed_body]
    end

    baseline = entry_write_counts
    expect(baseline[:entries]).to eq(2)
    expect(Entry.where(id: entries).pluck(:discarded_at)).to eq([nil, nil])

    [[0, 1], [1, 0]].each do |requester, owner|
      foreign = entries[owner]
      key = SecureRandom.uuid
      not_found = [200, { "results" => [{ "entry_id" => foreign, "result" => "not_found" }] }]

      expect(send_bulk_delete.call(requester, [foreign], key)).to eq(not_found)
      expect(entry_write_counts).to eq(baseline)
      # The same key and body again is evaluated again, with the same answer and still no receipt.
      expect(send_bulk_delete.call(requester, [foreign], key)).to eq(not_found)
      expect(entry_write_counts).to eq(baseline)
      # With no receipt stored, a replay-only retry has nothing to answer from.
      replay = send_bulk_delete.call(requester, [foreign], key,
                                     "Idempotency-Replay" => "only", "Ownership-Generation" => "replay-only")
      expect(replay).to eq([404, { "reason" => "not_found" }])
      expect(entry_write_counts).to eq(baseline)
    end
    expect(Entry.where(id: entries).pluck(:discarded_at)).to eq([nil, nil])
  end

  it "answers a bulk delete naming only the other company's entry with not_found in both directions, discards nothing and stores no receipt" do
    arrange = timekeeping_arrange
    first_company = arrange.company
    second_company = arrange.company
    seeded = [first_company, second_company].to_h do |company|
      owner = arrange.user(company:, role: "owner")
      [company, { token: arrange.token_for(owner),
                  entry: arrange.entry(company:, user: owner, project: arrange.project(company:)) }]
    end
    entry_ids = seeded.values.map { |values| values.fetch(:entry) }
    entries_before = Entry.where(id: entry_ids).order(:id).map(&:attributes)
    receipts_before = [first_company, second_company].index_with { |company| IdempotencyReceipt.where(company_id: company).count }
    expect(entries_before.map { |entry| entry.fetch("discarded_at") }).to eq([nil, nil])

    [[first_company, second_company], [second_company, first_company]].each do |requester, owner|
      foreign_entry = seeded.fetch(owner).fetch(:entry)
      post "/v1/companies/#{requester}/entries/bulk-delete",
           params: JSON.generate("entry_ids" => [foreign_entry]),
           headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{seeded.fetch(requester).fetch(:token)}",
                      "Idempotency-Key" => SecureRandom.uuid,
                      "Ownership-Generation" => arrange.current_generation.to_s }

      expect([response.status, response.parsed_body])
        .to eq([200, { "results" => [{ "entry_id" => foreign_entry, "result" => "not_found" }] }])
    end

    # "Each spec shows that no receipt row is written for a request carrying only another company's ids."
    expect([first_company, second_company].index_with { |company| IdempotencyReceipt.where(company_id: company).count })
      .to eq(receipts_before)
    expect(Entry.where(id: entry_ids).order(:id).map(&:attributes)).to eq(entries_before)
  end
end


RSpec.describe "Entry write routes, retrying a bulk delete that changed nothing" do
  include_context "timekeeping entry writes"

  # "A request that changes nothing stores no receipt, and a retry of it is evaluated again."
  it "answers a replay-only retry of a bulk-delete that changed nothing with not_found, while a bulk-delete that discards stores exactly one receipt" do
    company_a = timekeeping_arrange.company
    company_b = timekeeping_arrange.company
    owner_a = timekeeping_arrange.user(company: company_a, role: "owner")
    owner_b = timekeeping_arrange.user(company: company_b, role: "owner")
    own_entry = timekeeping_arrange.entry(company: company_a, user: owner_a,
                                          project: timekeeping_arrange.project(company: company_a))
    foreign_entry = timekeeping_arrange.entry(company: company_b, user: owner_b,
                                              project: timekeeping_arrange.project(company: company_b))
    token = timekeeping_arrange.token_for(owner_a)
    send_bulk_delete = lambda do |entry_ids, key, replay_only: false|
      headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{token}",
                  "Idempotency-Key" => key,
                  "Ownership-Generation" => replay_only ? "replay-only" : timekeeping_arrange.current_generation.to_s }
      headers["Idempotency-Replay"] = "only" if replay_only
      post "/v1/companies/#{company_a}/entries/bulk-delete", params: JSON.generate("entry_ids" => entry_ids), headers: headers
      [response.status, response.parsed_body]
    end
    expect(entry_write_counts).to include(entries: 2, idempotency_receipts: 0)

    no_change_key = SecureRandom.uuid
    first = send_bulk_delete.call([foreign_entry], no_change_key)
    expect(first).to eq([200, { "results" => [{ "entry_id" => foreign_entry, "result" => "not_found" }] }])
    after_no_change = entry_write_counts
    expect(after_no_change).to include(idempotency_receipts: 0)

    # With no receipt stored, a replay-only retry has nothing to answer from.
    replay = send_bulk_delete.call([foreign_entry], no_change_key, replay_only: true)
    expect(replay).to eq([404, { "reason" => "not_found" }])
    expect(entry_write_counts).to eq(after_no_change)
    expect(Entry.find(foreign_entry).discarded_at).to be_nil

    # A bulk delete that does discard still stores its receipt, once, and replays it.
    changing_key = SecureRandom.uuid
    changed = send_bulk_delete.call([own_entry], changing_key)
    expect(changed).to eq([200, { "results" => [{ "entry_id" => own_entry, "result" => "deleted" }] }])
    expect(IdempotencyReceipt.where(company_id: company_a, key: changing_key).count).to eq(1)
    expect(send_bulk_delete.call([own_entry], changing_key, replay_only: true)).to eq(changed)
    expect(IdempotencyReceipt.where(company_id: [company_a, company_b]).count).to eq(1)
  end
end


RSpec.describe "Entry write routes: a key first used by a bulk delete that changed nothing" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "A request that changes nothing stores no receipt, and a retry of it is evaluated again."
  # The no-change attempt left no receipt, so the key is not yet claimed: a later body under it is a
  # first attempt, not idempotency_key_reused, and once that attempt changes an entry it stores the one receipt.
  it "lets a key whose first bulk delete named only another company's entry carry a later write that deletes once and then replays" do
    arrange = timekeeping_arrange
    company = arrange.company
    other_company = arrange.company
    owner = arrange.user(company:, role: "owner")
    own_entry = arrange.entry(company:, user: owner, project: arrange.project(company:))
    foreign_entry = arrange.entry(company: other_company, user: arrange.user(company: other_company, role: "employee"),
                                  project: arrange.project(company: other_company))
    before = entry_write_counts
    expect(before).to include(entries: 2, idempotency_receipts: 0)
    headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{arrange.token_for(owner)}",
                "Idempotency-Key" => SecureRandom.uuid, "Ownership-Generation" => arrange.current_generation.to_s }
    bulk_delete = lambda do |entry_ids|
      post "/v1/companies/#{company}/entries/bulk-delete", params: JSON.generate("entry_ids" => entry_ids), headers: headers
      [response.status, response.parsed_body]
    end

    expect(bulk_delete.call([foreign_entry]))
      .to eq([200, { "results" => [{ "entry_id" => foreign_entry, "result" => "not_found" }] }])
    expect(entry_write_counts).to eq(before)

    deleted = [200, { "results" => [{ "entry_id" => own_entry, "result" => "deleted" }] }]
    expect(bulk_delete.call([own_entry])).to eq(deleted)
    after_write = entry_write_counts
    expect(after_write[:idempotency_receipts]).to eq(1)
    discarded_at = Entry.find(own_entry).discarded_at
    expect(discarded_at).not_to be_nil

    expect(bulk_delete.call([own_entry])).to eq(deleted)
    expect(entry_write_counts).to eq(after_write)
    expect(Entry.find(own_entry).discarded_at).to eq(discarded_at)
    expect(Entry.find(foreign_entry).discarded_at).to be_nil
  end
end
