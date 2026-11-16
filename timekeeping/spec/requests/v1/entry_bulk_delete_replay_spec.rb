# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Entry write routes, replay-only bulk delete" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  let(:company) { timekeeping_arrange.company }
  let(:project) { timekeeping_arrange.project(company:) }
  let(:owner) { timekeeping_arrange.user(company:, role: "owner") }
  let(:employee) { timekeeping_arrange.user(company:, role: "employee") }

  def replay_only_bulk_delete_request(entry_ids, token, key:, replay_only: true, generation: "replay-only")
    headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{token}", "Idempotency-Key" => key,
                "Ownership-Generation" => generation.to_s }
    headers["Idempotency-Replay"] = "only" if replay_only
    post "/v1/companies/#{company}/entries/bulk-delete", params: JSON.generate("entry_ids" => entry_ids), headers: headers
    response
  end

  # A provider that does not read Idempotency-Replay sees an ordinary bulk delete;
  # the generation value is never a generation, so it refuses without writing.
  it "refuses a bulk delete whose Ownership-Generation is replay-only with stale_generation and discards nothing" do
    entry_ids = [timekeeping_arrange.entry(company:, user: employee, project:)]
    before = entry_write_counts

    answer = replay_only_bulk_delete_request(entry_ids, timekeeping_arrange.token_for(owner), key: SecureRandom.uuid,
                                                                                              replay_only: false)

    expect([answer.status, answer.parsed_body]).to eq([409, { "reason" => "stale_generation" }])
    expect(Entry.where(id: entry_ids).pluck(:discarded_at)).to eq([nil])
    expect(entry_write_counts).to eq(before)
  end

  it "answers a replay-only bulk delete with no stored receipt as not_found and discards nothing" do
    entry_ids = [timekeeping_arrange.entry(company:, user: employee, project:)]
    before = entry_write_counts

    answer = replay_only_bulk_delete_request(entry_ids, timekeeping_arrange.token_for(owner), key: SecureRandom.uuid)

    expect([answer.status, answer.parsed_body]).to eq([404, { "reason" => "not_found" }])
    expect(Entry.where(id: entry_ids).pluck(:discarded_at)).to eq([nil])
    expect(entry_write_counts).to eq(before)
  end

  it "answers a replay-only bulk delete retry with the first bulk delete's stored answer and writes nothing more" do
    entry_ids = [timekeeping_arrange.entry(company:, user: employee, project:),
                 timekeeping_arrange.entry(company:, user: employee, project:)]
    token = timekeeping_arrange.token_for(owner)
    key = SecureRandom.uuid
    first = replay_only_bulk_delete_request(entry_ids, token, key:, replay_only: false,
                                                              generation: timekeeping_arrange.current_generation)
    first_status = first.status
    first_body = first.parsed_body
    after_first = entry_write_counts

    replay = replay_only_bulk_delete_request(entry_ids, token, key:)

    expect(first_status).to eq(200)
    expect(first_body.fetch("results").pluck("result")).to eq(%w[deleted deleted])
    expect([replay.status, replay.parsed_body]).to eq([first_status, first_body])
    expect(entry_write_counts).to eq(after_first)
  end
end
