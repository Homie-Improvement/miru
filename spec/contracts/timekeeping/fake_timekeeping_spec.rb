# frozen_string_literal: true

require "rails_helper"
require_relative "entry_api_examples"
require_relative "idempotency_examples"
require_relative "entry_replay_examples"
require_relative "reservations_examples"

# Each group runs in its own context, with nothing from the other groups, to
# show a provider can run one group before the others exist.
RSpec.describe TimekeepingContract::FakeTimekeeping do
  include_context "timekeeping contract fakes"

  describe "the entry API contract alone" do
    it_behaves_like "timekeeping entry API contract"
  end

  describe "the reservations contract alone" do
    it_behaves_like "timekeeping reservations contract"
  end

  describe "the idempotency contract for entries and reservations" do
    it_behaves_like "timekeeping idempotency contract", contracts: [:entry_api, :reservations]
  end

  describe "the replay-only delete contract" do
    it_behaves_like "timekeeping entry replay contract"
  end
end

RSpec.describe TimekeepingContract::FakeTimekeeping, "in token mode" do
  let(:token_mode_company) { create(:company) }
  let(:token_mode_project) { create(:project, billable: true, client: create(:client, company: token_mode_company)) }
  let(:token_mode_fake) { described_class.new(token_public_key: timekeeping_key_pair.public_key) }
  let(:token_mode_entries_path) { "/v1/companies/#{token_mode_company.id}/entries" }

  def token_mode_member(role, extra_role: nil)
    create(:user, current_workspace_id: token_mode_company.id).tap do |user|
      create(:employment, company: token_mode_company, user:)
      user.add_role role, token_mode_company
      user.add_role extra_role, token_mode_company if extra_role
      token_mode_fake.register_user(id: user.id, company_id: token_mode_company.id, role: (extra_role || role).to_s)
    end
  end

  def token_mode_token(user, private_key: timekeeping_key_pair, **options)
    Timekeeping::UserToken.mint(user:, company: token_mode_company, private_key:, **options)
  end

  def token_mode_headers(token, **extra)
    { "Authorization" => "Bearer #{token}", "Ownership-Generation" => token_mode_fake.generation.to_s,
      "Idempotency-Key" => SecureRandom.uuid }.merge(extra)
  end

  def token_mode_create_body
    { "project_id" => token_mode_project.id, "work_date" => Date.current.iso8601, "duration" => 30.0,
      "note" => "token mode", "source" => "manual", "source_metadata" => {} }
  end

  before do
    token_mode_fake.register_company(id: token_mode_company.id, edit_days: token_mode_company.timesheet_edit_days)
    token_mode_fake.register_project(id: token_mode_project.id, company_id: token_mode_company.id)
  end

  it "creates an entry for a registered monolith user signed with a real write token" do
    admin = token_mode_member(:admin)

    response = token_mode_fake.call("POST", token_mode_entries_path, headers: token_mode_headers(token_mode_token(admin)),
                                                                     body: token_mode_create_body)

    expect(response.status).to eq(201)
    expect(token_mode_fake.stored_entry(response.body.fetch("id"))["user_id"]).to eq(admin.id)
  end

  it "answers 401 for a token signed with another key, an expired token and a read token on a write" do
    admin = token_mode_member(:admin)
    tokens = [
      token_mode_token(admin, private_key: OpenSSL::PKey::RSA.generate(2048)),
      token_mode_token(admin, now: 2.minutes.ago),
      token_mode_token(admin, purpose: :read)
    ]

    tokens.each do |token|
      response = token_mode_fake.call("POST", token_mode_entries_path, headers: token_mode_headers(token),
                                                                       body: token_mode_create_body)
      expect(response.status).to eq(401)
    end
  end

  it "answers 404 when the token's company is not the path's company" do
    admin = token_mode_member(:admin)
    other_company = create(:company)

    response = token_mode_fake.call("POST", "/v1/companies/#{other_company.id}/entries",
                                    headers: token_mode_headers(token_mode_token(admin)), body: token_mode_create_body)

    expect(response.status).to eq(404)
  end

  it "refuses an employee-first admin's update of a reserved entry through the locked-entry rule" do
    employee_first_admin = token_mode_member(:employee, extra_role: :admin)
    entry = token_mode_fake.add_entry(company_id: token_mode_company.id, user_id: employee_first_admin.id,
                                      project_id: token_mode_project.id, work_date: Date.current.iso8601)
    token_mode_fake.add_reservation(entry_id: entry.fetch("id"), invoice_id: 1, state: "provisional", disposition: "keep")

    response = token_mode_fake.call("PATCH", "#{token_mode_entries_path}/#{entry.fetch("id")}",
                                    headers: token_mode_headers(token_mode_token(employee_first_admin)),
                                    body: { "note" => "edited while locked" })

    expect(response.status).to eq(403)
    expect(token_mode_fake.stored_entry(entry.fetch("id"))["note"]).not_to eq("edited while locked")
  end

  # Generated by Descant: acceptance tests.
  # Acceptance: "Policies authorize the returned record."
  # An entry that changes after the monolith authorized it must not be deleted under that stale authorization.
  it "refuses a delete whose If-Match names a version the entry has moved past and keeps the entry" do
    admin = token_mode_member(:admin)
    entry = token_mode_fake.add_entry(company_id: token_mode_company.id, user_id: admin.id,
                                      project_id: token_mode_project.id, work_date: Date.current.iso8601)

    response = token_mode_fake.call("DELETE", "#{token_mode_entries_path}/#{entry.fetch("id")}",
                                    headers: token_mode_headers(token_mode_token(admin),
                                                                "If-Match" => (entry.fetch("version") + 5).to_s))

    expect(response.status).to eq(409)
    expect(response.body["reason"]).to eq("version_conflict")
    expect(token_mode_fake.stored_entry(entry.fetch("id"))["discarded_at"]).to be_nil
  end

  it "refuses a write carrying its own signed bearer nested in source_metadata" do
    admin = token_mode_member(:admin)
    token = token_mode_token(admin)
    body = token_mode_create_body.merge("source_metadata" => { "tool" => { "auth" => token } })

    response = token_mode_fake.call("POST", token_mode_entries_path, headers: token_mode_headers(token), body:)

    expect(response.status).to eq(422)
    expect(response.body["reason"]).to eq("credential_in_body")
  end

  it "refuses a write whose duration is not a JSON number, as Timekeeping does" do
    admin = token_mode_member(:admin)

    response = token_mode_fake.call("POST", token_mode_entries_path, headers: token_mode_headers(token_mode_token(admin)),
                                                                     body: token_mode_create_body.merge("duration" => "30"))

    expect(response.status).to eq(400)
  end

  it "records each request with its method, path and headers" do
    admin = token_mode_member(:admin)
    headers = token_mode_headers(token_mode_token(admin), "X-Request-Id" => "req-token-mode")

    token_mode_fake.call("POST", token_mode_entries_path, headers:, body: token_mode_create_body)

    expect(token_mode_fake.requests.size).to eq(1)
    expect(token_mode_fake.requests.first).to include(method: "POST", path: token_mode_entries_path)
    expect(token_mode_fake.requests.first[:headers]).to include("X-Request-Id" => "req-token-mode",
                                                               "Ownership-Generation" => token_mode_fake.generation.to_s)
  end

  it "answers the real clients' HTTP requests through the bridge" do
    admin = token_mode_member(:admin)
    route_timekeeping_to_fake(token_mode_fake, base_url: "http://timekeeping.test")
    entry = token_mode_fake.add_entry(company_id: token_mode_company.id, user_id: admin.id,
                                      project_id: token_mode_project.id, work_date: Date.current.iso8601)

    entries = with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV, timekeeping_key_pair.to_pem) do
      Timekeeping::EntryApiClient.new(base_url: "http://timekeeping.test").list_entries(
        company_id: token_mode_company.id, user_id: admin.id, from: Date.current - 1, to: Date.current + 1
      )
    end

    expect(entries.pluck("id")).to eq([entry.fetch("id")])
    expect(token_mode_fake.requests.first[:headers]["Authorization"]).to start_with("Bearer ")
  end
end

RSpec.describe Timekeeping::FakeLocalOwner do
  it "records each call with its method and arguments and answers lookups from the given entries" do
    entry = build(:timesheet_entry)
    local_owner = described_class.new(entries: { 7 => entry })

    found = local_owner.find_entry(context: :a_context, entry_id: 7)
    local_owner.destroy_entry(context: :a_context, entry: found)

    expect(found).to be(entry)
    expect(local_owner.calls).to eq([
      { method: :find_entry, kwargs: { context: :a_context, entry_id: 7 } },
      { method: :destroy_entry, kwargs: { context: :a_context, entry: } }
    ])
    expect { local_owner.find_entry(context: :a_context, entry_id: 8) }.to raise_error(ActiveRecord::RecordNotFound)
  end
end

# Generated by Descant: acceptance tests below.
RSpec.describe TimekeepingContract::FakeTimekeeping, "in token mode with a detach service token" do
  # "Make the fake (`spec/support/timekeeping/fake_timekeeping.rb`) check a service token's operations against `BACKGROUND_OPERATIONS`."
  # "The token's operations are exactly `[\"agents.detach_entries\"]`, each one is in `BACKGROUND_OPERATIONS`, and the fake refuses a token naming `detach_entries`."
  it "refuses a service token naming bare detach_entries and one bound to another company, and changes no entry" do
    fake = described_class.new(token_public_key: timekeeping_key_pair.public_key)
    company_id = 41
    agent_id = fake.add_agent(company_id:, user_id: 7)
    entry = fake.add_entry(company_id:, user_id: 7, project_id: 1, agent_id:)
    path = "/v1/companies/#{company_id}/agents/#{agent_id}/detach-entries"
    send_detach = lambda do |token|
      fake.call("POST", path, headers: { "Authorization" => "Bearer #{token}", "X-Request-Id" => SecureRandom.uuid },
                              body: { "operation_id" => SecureRandom.uuid, "generation" => fake.generation })
    end

    bare = Timekeeping::ServiceToken.mint(company_id:, operations: ["detach_entries"], private_key: timekeeping_key_pair)
    other_company = Timekeeping::ServiceToken.mint(company_id: company_id + 1, operations: ["agents.detach_entries"],
                                                   private_key: timekeeping_key_pair)
    wrong_key = Timekeeping::ServiceToken.mint(company_id:, operations: ["agents.detach_entries"],
                                               private_key: OpenSSL::PKey::RSA.generate(2048))
    now = Time.current.to_i
    signed_claims = { typ: "timekeeping_service", sub: "forged", company_id:, operations: ["agents.detach_entries"],
                      iat: now, exp: now + 60, jti: SecureRandom.uuid }
    shared_secret = SecureRandom.hex(32)
    hmac_signed = JWT.encode(signed_claims, shared_secret, "HS256")
    # Correctly signed, but the real verifier refuses a scalar operations claim.
    scalar_operations = JWT.encode(signed_claims.merge(operations: "agents.detach_entries"), timekeeping_key_pair,
                                   "RS256")

    expect(send_detach.call(bare).status).to eq(403)
    expect(send_detach.call(other_company).status).to eq(404)
    expect(send_detach.call(wrong_key).status).to eq(401)
    expect(send_detach.call(hmac_signed).status).to eq(401)
    expect(send_detach.call(shared_secret).status).to eq(401)
    expect(send_detach.call(scalar_operations).status).to eq(401)
    expect(fake.stored_entry(entry["id"])["agent_id"]).to eq(agent_id)

    granted = Timekeeping::ServiceToken.mint(company_id:, operations: ["agents.detach_entries"],
                                             private_key: timekeeping_key_pair)
    granted_answer = send_detach.call(granted)
    expect(granted_answer.status).to eq(200)
    expect(granted_answer.body["detached"]).to eq(1)
    expect(fake.stored_entry(entry["id"])["agent_id"]).to be_nil
  end
end

RSpec.describe TimekeepingContract::FakeTimekeeping, "replaying deletes" do
  let(:replay_company) { create(:company) }
  let(:replay_project) { create(:project, billable: true, client: create(:client, company: replay_company)) }
  let(:replay_fake) { described_class.new(token_public_key: timekeeping_key_pair.public_key) }
  let(:replay_admin) do
    create(:user, current_workspace_id: replay_company.id).tap do |user|
      create(:employment, company: replay_company, user:)
      user.add_role :admin, replay_company
      replay_fake.register_user(id: user.id, company_id: replay_company.id, role: "admin")
    end
  end

  before do
    replay_fake.register_company(id: replay_company.id, edit_days: replay_company.timesheet_edit_days)
    replay_fake.register_project(id: replay_project.id, company_id: replay_company.id)
  end

  def replay_entry
    replay_fake.add_entry(company_id: replay_company.id, user_id: replay_admin.id, project_id: replay_project.id,
                          work_date: Date.current.iso8601)
  end

  def replay_headers(key, generation, **extra)
    token = Timekeeping::UserToken.mint(user: replay_admin, company: replay_company, private_key: timekeeping_key_pair)
    { "Authorization" => "Bearer #{token}", "Ownership-Generation" => generation.to_s, "Idempotency-Key" => key }
      .merge(extra)
  end

  # "Replaying it needs a separate design that keeps the lookup-then-authorize order, and nothing is deleted twice meanwhile."
  it "replays a committed delete after the generation moves and refuses a replay-only delete with no receipt without discarding" do
    deleted = replay_entry
    kept = replay_entry
    key = SecureRandom.uuid
    first_generation = replay_fake.generation
    path = ->(entry) { "/v1/companies/#{replay_company.id}/entries/#{entry.fetch("id")}" }
    replay_only = { "Idempotency-Replay" => "only", "If-Match" => "replay-only" }

    first = replay_fake.call("DELETE", path.call(deleted), headers: replay_headers(key, first_generation))
    outbox_after_first = replay_fake.outbox.size
    replay_fake.generation = first_generation + 1

    replay = replay_fake.call("DELETE", path.call(deleted), headers: replay_headers(key, first_generation, **replay_only))
    missing = replay_fake.call("DELETE", path.call(kept),
                               headers: replay_headers(SecureRandom.uuid, replay_fake.generation, **replay_only))

    expect(first.status).to eq(200)
    expect([replay.status, replay.body]).to eq([first.status, first.body])
    expect([missing.status, missing.body]).to eq([404, { "reason" => "not_found" }])
    expect(replay_fake.outbox.size).to eq(outbox_after_first)
    expect(replay_fake.stored_entry(kept.fetch("id"))["discarded_at"]).to be_nil
  end
end

RSpec.describe TimekeepingContract::FakeTimekeeping, "replay-only deletes without a receipt" do
  let(:replay_miss_company) { create(:company) }
  let(:replay_miss_project) { create(:project, billable: true, client: create(:client, company: replay_miss_company)) }
  let(:replay_miss_fake) { described_class.new(token_public_key: timekeeping_key_pair.public_key) }
  let(:replay_miss_admin) do
    create(:user, current_workspace_id: replay_miss_company.id).tap do |user|
      create(:employment, company: replay_miss_company, user:)
      user.add_role :admin, replay_miss_company
      replay_miss_fake.register_user(id: user.id, company_id: replay_miss_company.id, role: "admin")
    end
  end

  before do
    replay_miss_fake.register_company(id: replay_miss_company.id, edit_days: replay_miss_company.timesheet_edit_days)
    replay_miss_fake.register_project(id: replay_miss_project.id, company_id: replay_miss_company.id)
  end

  # "do not treat every missing entry as a successful delete" - and a replay-only
  # request must never run the delete itself, even for a kept entry.
  it "answers a replay-only DELETE with no stored answer as not found and keeps the entry" do
    entry = replay_miss_fake.add_entry(company_id: replay_miss_company.id, user_id: replay_miss_admin.id,
                                       project_id: replay_miss_project.id, work_date: Date.current.iso8601)
    token = Timekeeping::UserToken.mint(user: replay_miss_admin, company: replay_miss_company,
                                        private_key: timekeeping_key_pair)
    headers = { "Authorization" => "Bearer #{token}", "Ownership-Generation" => replay_miss_fake.generation.to_s,
                "Idempotency-Key" => SecureRandom.uuid, "Idempotency-Replay" => "only", "If-Match" => "replay-only" }

    response = replay_miss_fake.call("DELETE", "/v1/companies/#{replay_miss_company.id}/entries/#{entry.fetch("id")}",
                                     headers:)

    expect([response.status, response.body]).to eq([404, { "reason" => "not_found" }])
    expect(replay_miss_fake.stored_entry(entry.fetch("id"))["discarded_at"]).to be_nil
    expect(replay_miss_fake.stored_entry(entry.fetch("id"))["version"]).to eq(entry.fetch("version"))
  end
end

RSpec.describe TimekeepingContract::FakeTimekeeping, "replay-only deletes with a receipt" do
  let(:replay_hit_company) { create(:company) }
  let(:replay_hit_project) { create(:project, billable: true, client: create(:client, company: replay_hit_company)) }
  let(:replay_hit_fake) { described_class.new(token_public_key: timekeeping_key_pair.public_key) }
  let(:replay_hit_admin) do
    create(:user, current_workspace_id: replay_hit_company.id).tap do |user|
      create(:employment, company: replay_hit_company, user:)
      user.add_role :admin, replay_hit_company
      replay_hit_fake.register_user(id: user.id, company_id: replay_hit_company.id, role: "admin")
    end
  end

  before do
    replay_hit_fake.register_company(id: replay_hit_company.id, edit_days: replay_hit_company.timesheet_edit_days)
    replay_hit_fake.register_project(id: replay_hit_project.id, company_id: replay_hit_company.id)
  end

  # "Allow delete retries to reach the stored answer." The receipt is read before
  # the generation check, as the real service does, so a moved generation cannot
  # turn a committed delete into a refusal.
  it "replays the stored delete answer for a replay-only DELETE sent after the generation advanced" do
    entry = replay_hit_fake.add_entry(company_id: replay_hit_company.id, user_id: replay_hit_admin.id,
                                      project_id: replay_hit_project.id, work_date: Date.current.iso8601)
    path = "/v1/companies/#{replay_hit_company.id}/entries/#{entry.fetch("id")}"
    token = Timekeeping::UserToken.mint(user: replay_hit_admin, company: replay_hit_company,
                                        private_key: timekeeping_key_pair)
    key = SecureRandom.uuid
    first = replay_hit_fake.call("DELETE", path, headers: {
      "Authorization" => "Bearer #{token}", "Ownership-Generation" => replay_hit_fake.generation.to_s,
      "Idempotency-Key" => key, "If-Match" => entry.fetch("version").to_s
    })
    discarded = replay_hit_fake.stored_entry(entry.fetch("id"))
    stale_generation = replay_hit_fake.generation
    replay_hit_fake.generation = stale_generation + 1

    replay = replay_hit_fake.call("DELETE", path, headers: {
      "Authorization" => "Bearer #{token}", "Ownership-Generation" => stale_generation.to_s,
      "Idempotency-Key" => key, "Idempotency-Replay" => "only", "If-Match" => "replay-only"
    })

    expect(first.status).to eq(200)
    expect([replay.status, replay.body]).to eq([first.status, first.body])
    expect(replay_hit_fake.stored_entry(entry.fetch("id"))).to eq(discarded)
  end
end
