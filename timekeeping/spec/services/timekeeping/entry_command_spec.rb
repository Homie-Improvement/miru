# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::EntryCommand do
  let(:facts) do
    Timekeeping::ReferenceClient::Facts.new(
      company_id: 3, edit_days: 30, users: [Timekeeping::ReferenceClient::User.new(id: 7, role: "owner")],
      projects: [Timekeeping::ReferenceClient::Project.new(id: 11, company_id: 3, billable: true, member_user_ids: [])],
      missing_project_ids: [], agents: []
    )
  end
  let(:reference_client) { instance_double(Timekeeping::ReferenceClient, fetch: facts) }
  let(:identity) { Timekeeping::Identity.new(kind: :user, status: :verified, user_id: 7, company_id: 3, role: "owner") }

  def build(route, body: {}, entry_id: nil, headers: { "Idempotency-Key" => "key-1", "Ownership-Generation" => "1" },
            raw_body: JSON.generate(body))
    described_class.build(route:, identity:, bearer: "caller-token", company_id: 3, entry_id:, headers:, raw_body:,
                          reference_client:, today: Date.new(2026, 3, 3))
  end

  def create_body(**fields)
    { "project_id" => 11, "work_date" => "2026-03-02", "duration" => 30.0 }.merge(fields.transform_keys(&:to_s))
  end

  it "builds a create with the receipt operation, the body fingerprint and the facts" do
    command = build(:create, body: create_body)

    expect(command).to have_attributes(operation: "create ", key: "key-1", actor_id: 7, role: "owner", project_id: 11,
                                       fingerprint: Digest::SHA256.hexdigest(JSON.generate(create_body)), facts:)
    expect(reference_client).to have_received(:fetch).with(company_id: 3, project_ids: [11])
  end

  it "names the path entry id in an update's operation and fetches no project it does not name" do
    command = build(:update, entry_id: "42", body: { "note" => "x" })

    expect([command.operation, command.entry_id]).to eq(["update 42", 42])
    expect(reference_client).to have_received(:fetch).with(company_id: 3, project_ids: [])
  end

  it "counts the same fields in another key order as another body" do
    first = build(:create, body: create_body)
    reordered = build(:create, raw_body: JSON.generate(create_body.to_a.reverse.to_h))

    expect(reordered.fingerprint).not_to eq(first.fingerprint)
  end

  it "refuses a missing or blank Idempotency-Key before reading the facts" do
    [{}, { "Idempotency-Key" => " " }].each do |headers|
      expect(build(:create, body: create_body, headers:)).to eq(Timekeeping::WriteOutcome.refusal(:idempotency_key_required))
    end
    expect(reference_client).not_to have_received(:fetch)
  end

  it "refuses the caller's bearer token in the body before reading the facts" do
    outcome = build(:create, body: create_body(source_metadata: { "token" => "caller-token" }))

    expect(outcome).to eq(Timekeeping::WriteOutcome.refusal(:credential_in_body))
    expect(reference_client).not_to have_received(:fetch)
  end

  it "answers a project id that is not an id as not_found before reading the facts" do
    expect(build(:create, body: create_body(project_id: "11; DROP"))).to eq(Timekeeping::WriteOutcome.refusal(:not_found))
    expect(reference_client).not_to have_received(:fetch)
  end

  # The writer refuses a project the facts do not hold, after the receipt, so
  # a retry of a committed write still replays.
  it "leaves a project the facts do not hold for the writer to refuse" do
    allow(reference_client).to receive(:fetch).and_return(facts.with(projects: [], missing_project_ids: [11]))

    expect(build(:create, body: create_body)).to be_a(described_class)
  end

  it "answers an entry id that is not an id as not_found" do
    expect(build(:destroy, entry_id: "12abc")).to eq(Timekeeping::WriteOutcome.refusal(:not_found))
  end

  it "answers unreadable facts as reference_unavailable" do
    allow(reference_client).to receive(:fetch).and_raise(Timekeeping::ReferenceClient::Unavailable)

    expect(build(:create, body: create_body)).to eq(Timekeeping::WriteOutcome.refusal(:reference_unavailable))
  end

  it "refuses a body that is not a JSON object, or a field of the wrong shape, as a bad request" do
    ["[1]", "{not json"].each do |raw_body|
      expect { build(:create, raw_body:) }.to raise_error(ActionController::BadRequest)
    end
    expect { build(:create, body: create_body(work_date: "2026-02-30")) }.to raise_error(ActionController::BadRequest)
    expect { build(:create, body: create_body.except("duration")) }.to raise_error(ActionController::BadRequest)
    expect { build(:bulk_delete, body: { "entry_ids" => 5 }) }.to raise_error(ActionController::BadRequest)
  end

  it "refuses a source or bill_status the monolith's projection cannot store, and accepts every one it can" do
    expect { build(:create, body: create_body(source: "fax")) }.to raise_error(ActionController::BadRequest)
    expect { build(:create, body: create_body(bill_status: "paid")) }.to raise_error(ActionController::BadRequest)

    %w[manual cli mcp automation import].each do |source|
      expect(build(:create, body: create_body(source:))).to be_a(described_class)
    end
    %w[non_billable unbilled billed].each do |bill_status|
      expect(build(:create, body: create_body(bill_status:))).to be_a(described_class)
    end
  end

  it "checks the body against the shared snapshot rules for the same nine fields, leaving project_id out" do
    expect(described_class::FIELD_SHAPES.keys).to eq(
      %w[work_date duration note source source_metadata bill_status agent_id proof_url proof_metadata]
    )
    expect(described_class::FIELD_SHAPES).to all(satisfy { |field, rule| rule == Timekeeping::SnapshotValues::RULES[field] })
  end

  it "still builds a bulk_move whose project_id is a decimal string" do
    command = build(:bulk_move, body: { "project_id" => "11", "entry_ids" => [42] })

    expect(command).to have_attributes(project_id: 11)
  end

  # "The base's EntryCommand enforces the allowed sources; this new producer bypasses it."
  # Sharing the snapshot rules must not narrow the requests the entry API accepts today.
  it "still accepts a decimal-string project_id on create and update while refusing source agent" do
    expect(build(:create, body: create_body(project_id: "11"))).to have_attributes(project_id: 11)
    expect(build(:update, entry_id: "42", body: { "project_id" => "11", "note" => "x" }))
      .to have_attributes(project_id: 11)

    expect { build(:create, body: create_body(source: "agent")) }
      .to raise_error(ActionController::BadRequest, /source/)
  end
end

# Generated by Descant: acceptance tests below.
RSpec.describe Timekeeping::EntryCommand, "replay-only header" do
  let(:replay_facts) do
    Timekeeping::ReferenceClient::Facts.new(
      company_id: 3, edit_days: 30, users: [Timekeeping::ReferenceClient::User.new(id: 7, role: "owner")],
      projects: [Timekeeping::ReferenceClient::Project.new(id: 11, company_id: 3, billable: true, member_user_ids: [])],
      missing_project_ids: [], agents: []
    )
  end
  let(:replay_reference_client) { instance_double(Timekeeping::ReferenceClient, fetch: replay_facts) }
  let(:replay_identity) do
    Timekeeping::Identity.new(kind: :user, status: :verified, user_id: 7, company_id: 3, role: "owner")
  end

  def build_replay(route, headers, raw_body: "")
    described_class.build(route:, identity: replay_identity, bearer: "caller-token", company_id: 3, entry_id: "42",
                          headers: { "Idempotency-Key" => "key-1", "Ownership-Generation" => "1" }.merge(headers),
                          raw_body:, reference_client: replay_reference_client, today: Date.new(2026, 3, 3))
  end

  # "Address this in follow-up design work with an authenticated replay path; do not treat every missing entry as a successful delete."
  it "marks only a destroy carrying Idempotency-Replay only as replay-only, scoped to the verified actor" do
    replay = build_replay(:destroy, { "Idempotency-Replay" => "only", "If-Match" => "replay-only" })
    plain = build_replay(:destroy, {})
    other_value = build_replay(:destroy, { "Idempotency-Replay" => "yes" })
    patch = build_replay(:update, { "Idempotency-Replay" => "only" }, raw_body: JSON.generate("note" => "x"))

    expect(replay).to have_attributes(replay_only: true, actor_id: 7, company_id: 3, operation: "destroy 42",
                                      key: "key-1")
    expect(replay.fingerprint).to eq(plain.fingerprint)
    expect([plain.replay_only, other_value.replay_only, patch.replay_only]).to eq([false, false, false])
  end
end

RSpec.describe Timekeeping::EntryCommand do
  let(:replay_facts) do
    Timekeeping::ReferenceClient::Facts.new(
      company_id: 3, edit_days: 30, users: [Timekeeping::ReferenceClient::User.new(id: 7, role: "owner")],
      projects: [Timekeeping::ReferenceClient::Project.new(id: 11, company_id: 3, billable: true, member_user_ids: [])],
      missing_project_ids: [], agents: []
    )
  end
  let(:replay_reference_client) { instance_double(Timekeeping::ReferenceClient, fetch: replay_facts) }
  let(:replay_identity) { Timekeeping::Identity.new(kind: :user, status: :verified, user_id: 7, company_id: 3, role: "owner") }

  def build_for_replay(route, headers:, body: {})
    described_class.build(route:, identity: replay_identity, bearer: "caller-token", company_id: 3, entry_id: "42",
                          headers:, raw_body: JSON.generate(body), reference_client: replay_reference_client,
                          today: Date.new(2026, 3, 3))
  end

  # "Replaying it needs a separate design that keeps the lookup-then-authorize order, and nothing is deleted twice meanwhile."
  # The replay-only rule is a DELETE-only rule; other write routes ignore the header.
  it "marks only a destroy carrying Idempotency-Replay only as replay_only" do
    plain = { "Idempotency-Key" => "key-1", "Ownership-Generation" => "1" }
    replay = plain.merge("Idempotency-Replay" => "only", "If-Match" => "replay-only")

    expect(build_for_replay(:destroy, headers: replay).replay_only).to be(true)
    expect(build_for_replay(:destroy, headers: plain).replay_only).to be(false)
    expect(build_for_replay(:destroy, headers: plain.merge("Idempotency-Replay" => "yes")).replay_only).to be(false)
    expect(build_for_replay(:update, headers: replay, body: { "note" => "x" }).replay_only).to be(false)
  end
end

RSpec.describe Timekeeping::EntryCommand do
  let(:replay_facts) do
    Timekeeping::ReferenceClient::Facts.new(
      company_id: 3, edit_days: 30, users: [Timekeeping::ReferenceClient::User.new(id: 7, role: "owner")],
      projects: [], missing_project_ids: [], agents: []
    )
  end
  let(:replay_reference_client) { instance_double(Timekeeping::ReferenceClient, fetch: replay_facts) }
  let(:replay_identity) { Timekeeping::Identity.new(kind: :user, status: :verified, user_id: 7, company_id: 3, role: "owner") }

  # "Allow delete retries to reach the stored answer." The replay must use the
  # same receipt identity (operation and key) as the first delete.
  it "marks a destroy carrying Idempotency-Replay only as replay_only with the same destroy operation and key" do
    headers = { "Idempotency-Key" => "key-1", "Ownership-Generation" => "1", "Idempotency-Replay" => "only",
                "If-Match" => "replay-only" }
    command = described_class.build(route: :destroy, identity: replay_identity, bearer: "caller-token", company_id: 3,
                                    entry_id: "42", headers:, raw_body: "", reference_client: replay_reference_client,
                                    today: Date.new(2026, 3, 3))
    plain = described_class.build(route: :destroy, identity: replay_identity, bearer: "caller-token", company_id: 3,
                                  entry_id: "42", headers: { "Idempotency-Key" => "key-1", "Ownership-Generation" => "1" },
                                  raw_body: "", reference_client: replay_reference_client, today: Date.new(2026, 3, 3))

    expect(command).to have_attributes(replay_only: true, operation: "destroy 42", key: "key-1")
    expect(command.fingerprint).to eq(plain.fingerprint)
    expect(plain.replay_only).to be(false)
  end
end

RSpec.describe Timekeeping::EntryCommand do
  let(:replay_scope_facts) do
    Timekeeping::ReferenceClient::Facts.new(
      company_id: 3, edit_days: 30, users: [Timekeeping::ReferenceClient::User.new(id: 7, role: "owner")],
      projects: [Timekeeping::ReferenceClient::Project.new(id: 11, company_id: 3, billable: true, member_user_ids: [])],
      missing_project_ids: [], agents: []
    )
  end
  let(:replay_scope_reference_client) { instance_double(Timekeeping::ReferenceClient, fetch: replay_scope_facts) }
  let(:replay_scope_identity) do
    Timekeeping::Identity.new(kind: :user, status: :verified, user_id: 7, company_id: 3, role: "owner")
  end

  def build_with_replay_header(route, value, body:, entry_id:)
    headers = { "Idempotency-Key" => "key-1", "Ownership-Generation" => "1", "Idempotency-Replay" => value }
    described_class.build(route:, identity: replay_scope_identity, bearer: "caller-token", company_id: 3, entry_id:,
                          headers:, raw_body: JSON.generate(body), reference_client: replay_scope_reference_client,
                          today: Date.new(2026, 3, 3))
  end

  # The replay-only rule belongs to the single-entry DELETE only; every other
  # write route must keep running its normal write.
  it "ignores Idempotency-Replay on update and create and on a destroy whose value is not only" do
    update = build_with_replay_header(:update, "only", body: { "note" => "x" }, entry_id: "42")
    create = build_with_replay_header(:create, "only",
                                      body: { "project_id" => 11, "work_date" => "2026-03-02", "duration" => 30.0 },
                                      entry_id: nil)
    other_value = build_with_replay_header(:destroy, "yes", body: {}, entry_id: "42")
    empty_value = build_with_replay_header(:destroy, "", body: {}, entry_id: "42")

    expect([update, create, other_value, empty_value].map(&:replay_only)).to eq([false, false, false, false])
  end
end
