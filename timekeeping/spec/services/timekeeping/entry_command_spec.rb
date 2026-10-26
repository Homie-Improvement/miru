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
end

# Generated by Descant: acceptance tests below.
RSpec.describe Timekeeping::EntryCommand, "shared snapshot value rules" do
  let(:shared_rules_facts) do
    Timekeeping::ReferenceClient::Facts.new(
      company_id: 3, edit_days: 30, users: [Timekeeping::ReferenceClient::User.new(id: 7, role: "owner")],
      projects: [Timekeeping::ReferenceClient::Project.new(id: 11, company_id: 3, billable: true, member_user_ids: [])],
      missing_project_ids: [], agents: []
    )
  end
  let(:shared_rules_client) { instance_double(Timekeeping::ReferenceClient, fetch: shared_rules_facts) }
  let(:shared_rules_identity) do
    Timekeeping::Identity.new(kind: :user, status: :verified, user_id: 7, company_id: 3, role: "owner")
  end

  def shared_rules_build(body)
    described_class.build(route: :create, identity: shared_rules_identity, bearer: "caller-token", company_id: 3,
                          entry_id: nil, headers: { "Idempotency-Key" => "key-1", "Ownership-Generation" => "1" },
                          raw_body: JSON.generate(body), reference_client: shared_rules_client,
                          today: Date.new(2026, 3, 3))
  end

  # "The base's EntryCommand enforces the allowed sources; this new producer bypasses it."
  it "still refuses source agent and still accepts a decimal-string project_id after sharing the value rules" do
    body = { "project_id" => 11, "work_date" => "2026-03-02", "duration" => 30.0 }

    expect { shared_rules_build(body.merge("source" => "agent")) }
      .to raise_error(ActionController::BadRequest, /source/)
    expect(shared_rules_build(body.merge("project_id" => "11"))).to have_attributes(project_id: 11)
  end
end

RSpec.describe Timekeeping::EntryCommand do
  let(:string_project_facts) do
    Timekeeping::ReferenceClient::Facts.new(
      company_id: 3, edit_days: 30, users: [Timekeeping::ReferenceClient::User.new(id: 7, role: "owner")],
      projects: [Timekeeping::ReferenceClient::Project.new(id: 11, company_id: 3, billable: true, member_user_ids: [])],
      missing_project_ids: [], agents: []
    )
  end
  let(:string_project_client) { instance_double(Timekeeping::ReferenceClient, fetch: string_project_facts) }
  let(:string_project_identity) do
    Timekeeping::Identity.new(kind: :user, status: :verified, user_id: 7, company_id: 3, role: "owner")
  end

  def build_with_string_project(route, body, entry_id: nil)
    described_class.build(route:, identity: string_project_identity, bearer: "caller-token", company_id: 3, entry_id:,
                          headers: { "Idempotency-Key" => "key-1", "Ownership-Generation" => "1" },
                          raw_body: JSON.generate(body), reference_client: string_project_client,
                          today: Date.new(2026, 3, 3))
  end

  # "The base's EntryCommand enforces the allowed sources; this new producer bypasses it."
  # Sharing the snapshot rules must not narrow the requests the entry API accepts today.
  it "still accepts a decimal-string project_id while refusing source agent" do
    create = build_with_string_project(:create, { "project_id" => "11", "work_date" => "2026-03-02", "duration" => 30.0 })
    expect(create.project_id).to eq(11)

    update = build_with_string_project(:update, { "project_id" => "11", "note" => "x" }, entry_id: "42")
    expect(update.project_id).to eq(11)

    expect do
      build_with_string_project(:create, { "project_id" => 11, "work_date" => "2026-03-02", "duration" => 30.0,
                                           "source" => "agent" })
    end.to raise_error(ActionController::BadRequest, /source/)
  end
end
