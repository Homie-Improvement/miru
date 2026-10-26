# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

RSpec.describe Timekeeping::EntryWriter do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  let(:company) { timekeeping_arrange.company }
  let(:project) { timekeeping_arrange.project(company:) }
  let(:owner) { timekeeping_arrange.user(company:, role: "owner") }
  let(:owner_token) { timekeeping_arrange.token_for(owner) }
  let(:entry_id) { timekeeping_arrange.entry(company:, user: owner, project:) }

  def command(route, **options)
    build_entry_command(route, token: owner_token, **options)
  end

  def create_body(**fields)
    { "project_id" => project, "work_date" => "2026-03-02", "duration" => 60.0, "note" => "Planning",
      "source" => "manual", "source_metadata" => {} }.merge(fields.transform_keys(&:to_s))
  end

  describe "a failure inside the transaction" do
    %i[entry_written audit_written outbox_written receipt_written].each do |step|
      it "leaves no entry, audit, outbox or receipt row when it raises after #{step}" do
        patch = command(:update, entry_id:, body: { "note" => "Edited" })
        before = entry_write_counts
        failing = described_class.new(checkpoint: ->(reached) { raise "failed after #{step}" if reached == step })

        expect { failing.call(patch) }.to raise_error(RuntimeError, "failed after #{step}")
        expect(entry_write_counts).to eq(before)
        expect(Entry.find(entry_id).note).to eq("Design review")
      end
    end
  end

  describe "a receipt for the same key inserted by another connection after the receipt check" do
    def insert_receipt_from_another_connection(create, fingerprint:)
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          IdempotencyReceipt.create!(company_id: company, actor_type: "user", actor_id: owner, operation: create.operation,
                                     key: create.key, fingerprint:, status: 201, body: '{"stored":true}',
                                     created_at: Time.current)
        end
      end.join
    end

    it "replays the stored answer when the fingerprint matches and keeps none of the writer's rows" do
      create = command(:create, body: create_body)
      checkpoint = lambda do |step|
        insert_receipt_from_another_connection(create, fingerprint: create.fingerprint) if step == :receipt_checked
      end

      outcome = described_class.new(checkpoint:).call(create)

      expect([outcome.status, outcome.body]).to eq([201, '{"stored":true}'])
      expect(entry_write_counts.slice(:entries, :audit_events, :outbox_snapshots, :idempotency_receipts))
        .to eq(entries: 0, audit_events: 0, outbox_snapshots: 0, idempotency_receipts: 1)
    end

    it "answers idempotency_key_reused when the fingerprint differs and keeps none of the writer's rows" do
      create = command(:create, body: create_body)
      checkpoint = ->(step) { insert_receipt_from_another_connection(create, fingerprint: "other") if step == :receipt_checked }

      outcome = described_class.new(checkpoint:).call(create)

      expect([outcome.status, JSON.parse(outcome.body)]).to eq([422, { "reason" => "idempotency_key_reused" }])
      expect(Entry.count).to eq(0)
    end
  end

  describe "a successful PATCH" do
    it "writes the entry with version + 1, one audit row, one exact outbox row and one receipt" do
      created_at = Entry.find(entry_id).created_at
      patch = command(:update, entry_id:, body: { "note" => "Edited", "proof_metadata" => { "run" => 2 } }, if_match: "1")

      outcome = described_class.new.call(patch)

      entry = Entry.find(entry_id)
      expect(outcome.status).to eq(200)
      expect([entry.version, entry.note]).to eq([2, "Edited"])

      audit = AuditEvent.sole
      expect(audit.attributes).to include("company_id" => company, "entry_id" => entry_id, "actor_type" => "user",
                                          "actor_id" => owner, "action" => "update")
      expect(audit.before).to include("note" => "Design review", "version" => 1)
      expect(audit.after).to include("note" => "Edited", "version" => 2)
      expect(audit.entry_created_at).to eq(created_at)

      outbox = OutboxSnapshot.sole.attributes
      contract_fields = YAML.safe_load_file(Rails.root.join("../contracts/timekeeping/entry_snapshots.yml")).fetch("entry_fields")
      expect(outbox.keys).to match_array(contract_fields + %w[generation outbox_position enqueued_at sent_at])
      # The database clock fills enqueued_at, so the frozen spec clock cannot pin its value.
      expect(outbox["enqueued_at"]).to be_a(Time)
      expect(outbox["sent_at"]).to be_nil
      expect(outbox).to include("id" => entry_id, "company_id" => company, "version" => 2, "note" => "Edited",
                                "generation" => timekeeping_arrange.current_generation, "locked" => false)
      expect(outbox.values.map(&:to_s)).to all(satisfy { |value| !value.include?(owner_token) })

      receipt = IdempotencyReceipt.sole
      expect(receipt.attributes).to include("company_id" => company, "actor_type" => "user", "actor_id" => owner,
                                            "operation" => "update #{entry_id}", "key" => patch.key, "status" => 200)
      expect(receipt.body).to eq(outcome.body)
      expect(JSON.parse(receipt.body)).to include("id" => entry_id, "version" => 2)
    end

    it "replays the same key and body without changing the entry again, and refuses a different body" do
      key = SecureRandom.uuid
      first = described_class.new.call(command(:update, entry_id:, key:, body: { "note" => "Edited" }))
      replay = described_class.new.call(command(:update, entry_id:, key:, body: { "note" => "Edited" }))
      reused = described_class.new.call(command(:update, entry_id:, key:, body: { "note" => "Other" }))

      expect([replay.status, replay.body]).to eq([first.status, first.body])
      expect([reused.status, JSON.parse(reused.body)]).to eq([422, { "reason" => "idempotency_key_reused" }])
      expect(Entry.find(entry_id).version).to eq(2)
      expect(entry_write_counts.slice(:audit_events, :outbox_snapshots, :idempotency_receipts))
        .to eq(audit_events: 1, outbox_snapshots: 1, idempotency_receipts: 1)
    end
  end

  it "stores a create that omits bill_status as unbilled, with an empty audit before value" do
    outcome = described_class.new.call(command(:create, body: create_body))

    expect(outcome.status).to eq(201)
    expect(Entry.sole.bill_status).to eq("unbilled")
    expect(AuditEvent.sole.before).to be_nil
  end

  it "writes no receipt for a conflict, so a retry with the same key is evaluated again" do
    key = SecureRandom.uuid
    conflict = described_class.new.call(command(:update, entry_id:, key:, body: { "note" => "Edited" }, if_match: "7"))
    retried = described_class.new.call(command(:update, entry_id:, key:, body: { "note" => "Edited" }, if_match: "7"))
    fixed = described_class.new.call(command(:update, entry_id:, key:, body: { "note" => "Edited" }, if_match: "1"))

    expect([conflict.status, retried.status, fixed.status]).to eq([409, 409, 200])
    expect(IdempotencyReceipt.count).to eq(1)
  end

  it "discards on DELETE and carries discarded_at in the outbox row" do
    outcome = described_class.new.call(command(:destroy, entry_id:))

    expect(outcome.status).to eq(200)
    expect(Entry.find(entry_id).discarded_at).to eq(Time.current)
    expect(OutboxSnapshot.sole.discarded_at).to eq(Time.current)
  end
end

# Generated by Descant: acceptance tests below.
RSpec.describe Timekeeping::EntryWriter, "agent ownership" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # The entry API must not commit an agent_id "without checking that the agent
  # exists and belongs to the entry's company and user (design rule S7)".
  it "refuses a create whose agent belongs to another user of the company and writes no entry, audit, outbox or receipt row" do
    company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    owner = timekeeping_arrange.user(company:, role: "owner")
    colleague = timekeeping_arrange.user(company:, role: "employee")
    colleague_agent = timekeeping_arrange.agent(company:, user: colleague)
    body = { "project_id" => project, "work_date" => "2026-03-02", "duration" => 60.0, "note" => "Planning",
             "source" => "manual", "source_metadata" => {}, "agent_id" => colleague_agent }
    create = build_entry_command(:create, token: timekeeping_arrange.token_for(owner), body:)
    before = entry_write_counts

    outcome = described_class.new.call(create)

    expect([outcome.status, JSON.parse(outcome.body)]).to eq([404, { "reason" => "not_found" }])
    expect(entry_write_counts).to eq(before)
  end
end

RSpec.describe Timekeeping::EntryWriter, "agent ownership on an update that changes only user_id" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  let(:agent_company) { timekeeping_arrange.company }
  let(:agent_project) { timekeeping_arrange.project(company: agent_company) }
  let(:agent_owner_user) { timekeeping_arrange.user(company: agent_company, role: "owner") }
  let(:agent_other_user) { timekeeping_arrange.user(company: agent_company, role: "employee") }
  let(:owners_agent) { timekeeping_arrange.agent(company: agent_company, user: agent_owner_user) }

  it "refuses an update that changes only user_id away from the stored agent's user and writes nothing" do
    entry_id = timekeeping_arrange.entry(company: agent_company, user: agent_owner_user, project: agent_project,
                                         agent_id: owners_agent)
    agent_other_user
    before = entry_write_counts

    # The body carries no agent_id, but the committed pair would be [stored agent, new user],
    # which the monolith projection refuses and which would hold back every later delivery.
    patch = build_entry_command(:update, token: timekeeping_arrange.token_for(agent_owner_user), entry_id:,
                                         body: { "user_id" => agent_other_user })
    outcome = described_class.new.call(patch)

    expect([outcome.status, JSON.parse(outcome.body)]).to eq([404, { "reason" => "not_found" }])
    expect(entry_write_counts).to eq(before)
    expect(Entry.find(entry_id).user_id).to eq(agent_owner_user)
    expect(OutboxSnapshot.where(id: entry_id).count).to eq(0)
  end
end

RSpec.describe Timekeeping::EntryWriter, "agent ownership on a create with an unknown or foreign agent" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  let(:home_company) { timekeeping_arrange.company }
  let(:home_project) { timekeeping_arrange.project(company: home_company) }
  let(:home_owner) { timekeeping_arrange.user(company: home_company, role: "owner") }
  let(:foreign_company) { timekeeping_arrange.company }
  let(:foreign_user) { timekeeping_arrange.user(company: foreign_company, role: "owner") }
  let(:foreign_agent) { timekeeping_arrange.agent(company: foreign_company, user: foreign_user) }

  def agent_create_body(agent_id)
    { "project_id" => home_project, "work_date" => "2026-03-02", "duration" => 60.0, "note" => "Planning",
      "source" => "manual", "source_metadata" => {}, "agent_id" => agent_id }
  end

  it "refuses a create naming another company's agent exactly like a missing agent and persists no row for either" do
    token = timekeeping_arrange.token_for(home_owner)
    missing_agent = foreign_agent + 10_000
    before = entry_write_counts

    foreign = described_class.new.call(build_entry_command(:create, token:, body: agent_create_body(foreign_agent)))
    missing = described_class.new.call(build_entry_command(:create, token:, body: agent_create_body(missing_agent)))

    expect([foreign.status, JSON.parse(foreign.body)]).to eq([404, { "reason" => "not_found" }])
    expect([missing.status, missing.body]).to eq([foreign.status, foreign.body])
    expect(entry_write_counts).to eq(before)
  end
end

RSpec.describe Timekeeping::EntryWriter, "agent ownership on a retried create" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  let(:retry_company) { timekeeping_arrange.company }
  let(:retry_project) { timekeeping_arrange.project(company: retry_company) }
  let(:retry_owner) { timekeeping_arrange.user(company: retry_company, role: "owner") }
  let(:retry_agent) { timekeeping_arrange.agent(company: retry_company, user: retry_owner) }

  it "replays a committed agent create after its agent leaves the reference facts and writes no second row" do
    token = timekeeping_arrange.token_for(retry_owner)
    key = SecureRandom.uuid
    body = { "project_id" => retry_project, "work_date" => "2026-03-02", "duration" => 60.0, "note" => "Planning",
             "source" => "manual", "source_metadata" => {}, "agent_id" => retry_agent }

    first = described_class.new.call(build_entry_command(:create, token:, key:, body:))
    expect(first.status).to eq(201)
    expect(Entry.sole.agent_id).to eq(retry_agent)

    # The monolith no longer lists the agent. The agent check reads facts that can change, so it
    # must run after the receipt read: a retry of the committed create replays, never a false 404.
    WebMock.stub_request(:get, TimekeepingProviderArrange::REFERENCE_HOST).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: JSON.generate(company_id: retry_company, edit_days: TimekeepingProviderArrange::EDIT_DAYS,
                          users: [{ id: retry_owner, role: "owner" }],
                          projects: [{ id: retry_project, company_id: retry_company, billable: true, member_user_ids: [] }],
                          missing_project_ids: [], agents: [])
    )
    replay = described_class.new.call(build_entry_command(:create, token:, key:, body:))

    expect([replay.status, replay.body]).to eq([first.status, first.body])
    expect(entry_write_counts.slice(:entries, :audit_events, :outbox_snapshots, :idempotency_receipts))
      .to eq(entries: 1, audit_events: 1, outbox_snapshots: 1, idempotency_receipts: 1)
  end
end

RSpec.describe Timekeeping::EntryWriter, "agent ownership on a create with the user's own agent" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  let(:own_company) { timekeeping_arrange.company }
  let(:own_project) { timekeeping_arrange.project(company: own_company) }
  let(:own_owner) { timekeeping_arrange.user(company: own_company, role: "owner") }
  let(:own_agent) { timekeeping_arrange.agent(company: own_company, user: own_owner) }

  it "commits a create with the user's own agent and stores that agent on the entry and its outbox snapshot" do
    body = { "project_id" => own_project, "work_date" => "2026-03-02", "duration" => 60.0, "note" => "Planning",
             "source" => "manual", "source_metadata" => {}, "agent_id" => own_agent }

    outcome = described_class.new.call(build_entry_command(:create, token: timekeeping_arrange.token_for(own_owner), body:))

    expect(outcome.status).to eq(201)
    entry = Entry.sole
    expect([entry.agent_id, entry.user_id]).to eq([own_agent, own_owner])
    expect(OutboxSnapshot.sole.attributes).to include("id" => entry.id, "agent_id" => own_agent, "user_id" => own_owner)
  end
end

RSpec.describe Timekeeping::EntryWriter do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "Timekeeping::EntryCommand or EntryDecision to refuse an unknown or
  # foreign agent before the write."
  it "answers not_found from the writer for a create whose agent id names no agent in the company and stores no receipt" do
    company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    owner = timekeeping_arrange.user(company:, role: "owner")
    own_agent = timekeeping_arrange.agent(company:, user: owner)
    body = { "project_id" => project, "work_date" => "2026-03-02", "duration" => 60.0, "note" => "Planning",
             "source" => "manual", "source_metadata" => {}, "agent_id" => own_agent + 10_000 }
    create = build_entry_command(:create, token: timekeeping_arrange.token_for(owner), body:)
    before = entry_write_counts

    outcome = described_class.new.call(create)

    expect([outcome.status, JSON.parse(outcome.body)]).to eq([404, { "reason" => "not_found" }])
    expect(entry_write_counts).to eq(before)
  end
end

RSpec.describe Timekeeping::EntryWriter do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # The issue: the API "still commits any positive agent_id without checking
  # that the agent exists and belongs to the entry's company and user (design
  # rule S7)". The check reads the pair the write commits, so an update that
  # changes only user_id on an agent entry is refused too.
  it "refuses a create with a same-company agent of another user and an update moving an agent entry to another user, writing nothing" do
    company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    owner = timekeeping_arrange.user(company:, role: "owner")
    colleague = timekeeping_arrange.user(company:, role: "employee")
    owner_agent = timekeeping_arrange.agent(company:, user: owner)
    colleague_agent = timekeeping_arrange.agent(company:, user: colleague)
    token = timekeeping_arrange.token_for(owner)
    agent_entry = timekeeping_arrange.entry(company:, user: owner, project:, agent_id: owner_agent)
    create_body = { "project_id" => project, "work_date" => "2026-03-02", "duration" => 60.0, "note" => "Planning",
                    "source" => "manual", "source_metadata" => {}, "agent_id" => colleague_agent }
    before = entry_write_counts

    create = described_class.new.call(build_entry_command(:create, token:, body: create_body))
    expect([create.status, JSON.parse(create.body)]).to eq([404, { "reason" => "not_found" }])

    move = described_class.new.call(build_entry_command(:update, token:, entry_id: agent_entry, body: { "user_id" => colleague }))
    expect([move.status, JSON.parse(move.body)]).to eq([404, { "reason" => "not_found" }])

    expect(entry_write_counts.except(:idempotency_receipts)).to eq(before.except(:idempotency_receipts))
    expect(Entry.find(agent_entry).user_id).to eq(owner)
  end
end

RSpec.describe Timekeeping::EntryWriter do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  it "creates an entry with the acting user's own agent" do
    company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    owner = timekeeping_arrange.user(company:, role: "owner")
    agent = timekeeping_arrange.agent(company:, user: owner)
    body = { "project_id" => project, "work_date" => "2026-03-02", "duration" => 60.0, "note" => "Planning",
             "source" => "manual", "source_metadata" => {}, "agent_id" => agent }

    outcome = described_class.new.call(build_entry_command(:create, token: timekeeping_arrange.token_for(owner), body:))

    expect(outcome.status).to eq(201)
    expect([Entry.sole.agent_id, Entry.sole.user_id]).to eq([agent, owner])
    expect(OutboxSnapshot.count).to eq(1)
  end
end

RSpec.describe Timekeeping::EntryWriter do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "it still commits any positive agent_id without checking that the agent
  # exists and belongs to the entry's company and user (design rule S7)."
  # The body carries no agent_id: the stored agent stays, so the committed
  # pair would be the owner's agent with the colleague as user.
  it "refuses an update that moves an agent entry to another user and writes nothing" do
    company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    owner = timekeeping_arrange.user(company:, role: "owner")
    colleague = timekeeping_arrange.user(company:, role: "employee")
    agent = timekeeping_arrange.agent(company:, user: owner)
    entry_id = timekeeping_arrange.entry(company:, user: owner, project:, agent_id: agent)
    patch = build_entry_command(:update, token: timekeeping_arrange.token_for(owner), entry_id:,
                                         body: { "user_id" => colleague })
    before = entry_write_counts

    outcome = described_class.new.call(patch)

    expect([outcome.status, JSON.parse(outcome.body)]).to eq([404, { "reason" => "not_found" }])
    expect(entry_write_counts).to eq(before)
    expect(Entry.find(entry_id).user_id).to eq(owner)
  end
end

RSpec.describe Timekeeping::EntryWriter do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  it "clears an entry's agent with a null agent_id update" do
    company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    owner = timekeeping_arrange.user(company:, role: "owner")
    agent = timekeeping_arrange.agent(company:, user: owner)
    entry_id = timekeeping_arrange.entry(company:, user: owner, project:, agent_id: agent)
    patch = build_entry_command(:update, token: timekeeping_arrange.token_for(owner), entry_id:,
                                         body: { "agent_id" => nil })

    outcome = described_class.new.call(patch)

    expect(outcome.status).to eq(200)
    expect(Entry.find(entry_id).agent_id).to be_nil
  end
end

RSpec.describe Timekeeping::EntryWriter, "agent check on a retried create" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # The agent check reads facts the monolith can change, so it must run after the idempotency receipt:
  # a retry of a committed write replays its stored answer instead of a new not_found.
  it "replays a committed create with an agent after the agent leaves the reference facts" do
    company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    owner = timekeeping_arrange.user(company:, role: "owner")
    agent = timekeeping_arrange.agent(company:, user: owner)
    token = timekeeping_arrange.token_for(owner)
    key = SecureRandom.uuid
    body = { "project_id" => project, "work_date" => "2026-03-02", "duration" => 60.0, "note" => "Planning",
             "source" => "manual", "source_metadata" => {}, "agent_id" => agent }

    first = described_class.new.call(build_entry_command(:create, token:, body:, key:))
    expect(first.status).to eq(201)

    facts_without_agent = {
      company_id: company, edit_days: 30, users: [{ id: owner, role: "owner" }],
      projects: [{ id: project, company_id: company, billable: true, member_user_ids: [] }],
      missing_project_ids: [], agents: []
    }
    WebMock.stub_request(:get, TimekeepingProviderArrange::REFERENCE_HOST)
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: JSON.generate(facts_without_agent))

    retried = described_class.new.call(build_entry_command(:create, token:, body:, key:))

    expect([retried.status, retried.body]).to eq([201, first.body])
    expect(Entry.count).to eq(1)
    expect(OutboxSnapshot.count).to eq(1)
  end
end

RSpec.describe Timekeeping::EntryWriter, "agent of another company on create" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # The issue asks to "refuse an unknown or foreign agent before the write". entry_api.yml's company_mismatch
  # rule: "An entry or user of another company answers not_found, exactly as a missing id does." A different
  # answer would let a caller probe which agent ids exist in other companies.
  it "answers another company's agent exactly as an agent id that does not exist and writes nothing" do
    company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    owner = timekeeping_arrange.user(company:, role: "owner")
    token = timekeeping_arrange.token_for(owner)
    other_company = timekeeping_arrange.company
    other_user = timekeeping_arrange.user(company: other_company, role: "owner")
    foreign_agent = timekeeping_arrange.agent(company: other_company, user: other_user)
    missing_agent = foreign_agent + 10_000
    body = ->(agent_id) do
      { "project_id" => project, "work_date" => "2026-03-02", "duration" => 60.0, "note" => "Planning",
        "source" => "manual", "source_metadata" => {}, "agent_id" => agent_id }
    end

    foreign = described_class.new.call(build_entry_command(:create, token:, body: body.call(foreign_agent)))
    missing = described_class.new.call(build_entry_command(:create, token:, body: body.call(missing_agent)))

    expect([foreign.status, JSON.parse(foreign.body)]).to eq([404, { "reason" => "not_found" }])
    expect([missing.status, missing.body]).to eq([foreign.status, foreign.body])
    expect(Entry.count).to eq(0)
    expect(OutboxSnapshot.count).to eq(0)
  end
end
