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

  # The monolith refuses a locked edit while the user's lowest-id role in the
  # company is employee, even when they also hold admin there, so a token's
  # raised admin role must not let the writer change a reserved entry.
  describe "an admin token whose signed primary role is employee" do
    let(:raised_admin) { timekeeping_arrange.user(company:, role: "admin") }
    let(:colleague) { timekeeping_arrange.user(company:, role: "employee") }

    def raised_admin_token(primary_role:)
      now = Time.now.to_i
      JWT.encode({ sub: raised_admin, company_id: company, role: "admin", primary_role:, purpose: "write", iat: now,
                   exp: now + 300, jti: SecureRandom.uuid }, TimekeepingProviderArrange.signing_key, "RS256")
    end

    def colleague_entry(reserved:)
      timekeeping_arrange.entry(company:, user: colleague, project:).tap do |id|
        next unless reserved

        Reservation.create!(company_id: company, entry_id: id, invoice_id: 701, state: "committed",
                            disposition: "active", operation_id: SecureRandom.uuid, created_at: Time.current)
      end
    end

    def raised_admin_call(route, primary_role:, **options)
      described_class.new.call(build_entry_command(route, token: raised_admin_token(primary_role:), **options))
    end

    it "refuses an update of a colleague's reserved entry and leaves it unchanged" do
      reserved = colleague_entry(reserved: true)
      before = entry_write_counts

      outcome = raised_admin_call(:update, primary_role: "employee", entry_id: reserved, body: { "duration" => 5.0 })

      expect([outcome.status, JSON.parse(outcome.body)]).to eq([403, { "reason" => "forbidden" }])
      expect(entry_write_counts).to eq(before)
      expect(Entry.find(reserved).attributes).to include("duration" => 90.0, "version" => 1)
    end

    it "updates a colleague's unreserved entry" do
      free = colleague_entry(reserved: false)

      outcome = raised_admin_call(:update, primary_role: "employee", entry_id: free, body: { "note" => "Edited" })

      expect(outcome.status).to eq(200)
      expect(Entry.find(free).note).to eq("Edited")
    end

    it "updates a colleague's reserved entry when the primary role is admin too" do
      reserved = colleague_entry(reserved: true)

      outcome = raised_admin_call(:update, primary_role: "admin", entry_id: reserved, body: { "note" => "Edited" })

      expect(outcome.status).to eq(200)
      expect(Entry.find(reserved).note).to eq("Edited")
    end

    it "skips a colleague's reserved entry on a bulk move and moves the unreserved one" do
      reserved = colleague_entry(reserved: true)
      free = colleague_entry(reserved: false)
      target_project = timekeeping_arrange.project(company:)

      outcome = raised_admin_call(:bulk_move, primary_role: "employee",
                                              body: { "entry_ids" => [reserved, free], "project_id" => target_project })

      expect(outcome.status).to eq(200)
      expect(Entry.find(reserved).project_id).to eq(project)
      expect(Entry.find(free).project_id).to eq(target_project)
    end
  end

  it "discards on DELETE and carries discarded_at in the outbox row" do
    outcome = described_class.new.call(command(:destroy, entry_id:))

    expect(outcome.status).to eq(200)
    expect(Entry.find(entry_id).discarded_at).to eq(Time.current)
    expect(OutboxSnapshot.sole.discarded_at).to eq(Time.current)
  end
end

# Generated by Descant: acceptance tests below.
# The entry API must not commit an agent_id "without checking that the agent
# exists and belongs to the entry's company and user (design rule S7)". Every
# refusal answers not_found and writes no entry, audit, outbox or receipt row.
RSpec.describe Timekeeping::EntryWriter, "agent ownership" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  let(:agent_company) { timekeeping_arrange.company }
  let(:agent_project) { timekeeping_arrange.project(company: agent_company) }
  let(:agent_owner_user) { timekeeping_arrange.user(company: agent_company, role: "owner") }
  let(:agent_other_user) { timekeeping_arrange.user(company: agent_company, role: "employee") }
  let(:owners_agent) { timekeeping_arrange.agent(company: agent_company, user: agent_owner_user) }
  let(:agent_owner_token) { timekeeping_arrange.token_for(agent_owner_user) }

  def agent_create_body(agent_id)
    { "project_id" => agent_project, "work_date" => "2026-03-02", "duration" => 60.0, "note" => "Planning",
      "source" => "manual", "source_metadata" => {}, "agent_id" => agent_id }
  end

  def expect_agent_not_found(outcome)
    expect([outcome.status, JSON.parse(outcome.body)]).to eq([404, { "reason" => "not_found" }])
  end

  it "refuses a create whose agent belongs to another user of the company and writes nothing" do
    colleague_agent = timekeeping_arrange.agent(company: agent_company, user: agent_other_user)
    before = entry_write_counts

    outcome = described_class.new.call(build_entry_command(:create, token: agent_owner_token,
                                                                    body: agent_create_body(colleague_agent)))

    expect_agent_not_found(outcome)
    expect(entry_write_counts).to eq(before)
  end

  it "refuses an update that changes only user_id away from the stored agent's user and writes nothing" do
    entry_id = timekeeping_arrange.entry(company: agent_company, user: agent_owner_user, project: agent_project,
                                         agent_id: owners_agent)
    agent_other_user
    before = entry_write_counts

    # The body carries no agent_id, but the committed pair would be [stored agent, new user],
    # which the monolith projection refuses and which would hold back every later delivery.
    patch = build_entry_command(:update, token: agent_owner_token, entry_id:, body: { "user_id" => agent_other_user })
    outcome = described_class.new.call(patch)

    expect_agent_not_found(outcome)
    expect(entry_write_counts).to eq(before)
    expect(Entry.find(entry_id).user_id).to eq(agent_owner_user)
    expect(OutboxSnapshot.where(id: entry_id).count).to eq(0)
  end

  # entry_api.yml's company_mismatch rule: "An entry or user of another company answers not_found, exactly
  # as a missing id does." A different answer would let a caller probe which agent ids exist elsewhere.
  it "refuses a create naming another company's agent exactly like a missing agent and persists no row for either" do
    foreign_company = timekeeping_arrange.company
    foreign_user = timekeeping_arrange.user(company: foreign_company, role: "owner")
    foreign_agent = timekeeping_arrange.agent(company: foreign_company, user: foreign_user)
    missing_agent = foreign_agent + 10_000
    before = entry_write_counts

    foreign = described_class.new.call(build_entry_command(:create, token: agent_owner_token,
                                                                    body: agent_create_body(foreign_agent)))
    missing = described_class.new.call(build_entry_command(:create, token: agent_owner_token,
                                                                    body: agent_create_body(missing_agent)))

    expect_agent_not_found(foreign)
    expect([missing.status, missing.body]).to eq([foreign.status, foreign.body])
    expect(entry_write_counts).to eq(before)
  end

  it "commits a create with the user's own agent and stores that agent on the entry and its outbox snapshot" do
    outcome = described_class.new.call(build_entry_command(:create, token: agent_owner_token,
                                                                    body: agent_create_body(owners_agent)))

    expect(outcome.status).to eq(201)
    entry = Entry.sole
    expect([entry.agent_id, entry.user_id]).to eq([owners_agent, agent_owner_user])
    expect(OutboxSnapshot.sole.attributes)
      .to include("id" => entry.id, "agent_id" => owners_agent, "user_id" => agent_owner_user)
  end

  it "commits an update that keeps the stored agent, checked against the stored user" do
    entry_id = timekeeping_arrange.entry(company: agent_company, user: agent_owner_user, project: agent_project,
                                         agent_id: owners_agent)
    patch = build_entry_command(:update, token: agent_owner_token, entry_id:, body: { "note" => "Edited" })

    outcome = described_class.new.call(patch)

    expect(outcome.status).to eq(200)
    entry = Entry.find(entry_id)
    expect([entry.agent_id, entry.user_id, entry.note]).to eq([owners_agent, agent_owner_user, "Edited"])
    expect(OutboxSnapshot.sole.attributes)
      .to include("id" => entry_id, "agent_id" => owners_agent, "user_id" => agent_owner_user)
  end

  it "commits an update that changes user_id and agent_id together to another valid pair" do
    entry_id = timekeeping_arrange.entry(company: agent_company, user: agent_owner_user, project: agent_project,
                                         agent_id: owners_agent)
    other_users_agent = timekeeping_arrange.agent(company: agent_company, user: agent_other_user)
    patch = build_entry_command(:update, token: agent_owner_token, entry_id:,
                                         body: { "user_id" => agent_other_user, "agent_id" => other_users_agent })

    outcome = described_class.new.call(patch)

    expect(outcome.status).to eq(200)
    entry = Entry.find(entry_id)
    expect([entry.agent_id, entry.user_id]).to eq([other_users_agent, agent_other_user])
    expect(OutboxSnapshot.sole.attributes)
      .to include("id" => entry_id, "agent_id" => other_users_agent, "user_id" => agent_other_user)
  end

  it "replays a committed agent create after its agent leaves the reference facts and writes no second row" do
    key = SecureRandom.uuid
    body = agent_create_body(owners_agent)

    first = described_class.new.call(build_entry_command(:create, token: agent_owner_token, key:, body:))
    expect(first.status).to eq(201)
    expect(Entry.sole.agent_id).to eq(owners_agent)

    # The monolith no longer lists the agent. The agent check reads facts that can change, so it
    # must run after the receipt read: a retry of the committed create replays, never a false 404.
    WebMock.stub_request(:get, TimekeepingProviderArrange::REFERENCE_HOST).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: JSON.generate(company_id: agent_company, edit_days: TimekeepingProviderArrange::EDIT_DAYS,
                          users: [{ id: agent_owner_user, role: "owner" }],
                          projects: [{ id: agent_project, company_id: agent_company, billable: true, member_user_ids: [] }],
                          missing_project_ids: [], agents: [])
    )
    replay = described_class.new.call(build_entry_command(:create, token: agent_owner_token, key:, body:))

    expect([replay.status, replay.body]).to eq([first.status, first.body])
    expect(entry_write_counts.slice(:entries, :audit_events, :outbox_snapshots, :idempotency_receipts))
      .to eq(entries: 1, audit_events: 1, outbox_snapshots: 1, idempotency_receipts: 1)
  end
end

# Generated by Descant: acceptance tests below.
RSpec.describe Timekeeping::EntryWriter do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  let(:company) { timekeeping_arrange.company }
  let(:project) { timekeeping_arrange.project(company:) }
  let(:owner) { timekeeping_arrange.user(company:, role: "owner") }
  let(:owner_token) { timekeeping_arrange.token_for(owner) }
  let(:entry_id) { timekeeping_arrange.entry(company:, user: owner, project:) }

  # "mark_billed, detach_entries and entry updates that omit source republish whatever is stored, so a bad
  # stored value (for example from the checkpoint load) still reaches the outbox and stops delivery."
  it "refuses an update that omits source over a stored bad source, keeps nothing, and checks the retry again after repair" do
    Entry.find(entry_id).update_column(:source, "legacy")
    key = SecureRandom.uuid
    before = entry_write_counts

    refused = described_class.new.call(build_entry_command(:update, token: owner_token, entry_id:, key:,
                                                                     body: { "note" => "Edited" }))

    expect([refused.status, JSON.parse(refused.body)])
      .to eq([409, { "reason" => "unpublishable_entry", "entries" => [{ "entry_id" => entry_id, "fields" => ["source"] }] }])
    expect(entry_write_counts).to eq(before)
    expect(Entry.find(entry_id).note).to eq("Design review")

    Entry.find(entry_id).update_column(:source, "manual")
    retried = described_class.new.call(build_entry_command(:update, token: owner_token, entry_id:, key:,
                                                                     body: { "note" => "Edited" }))

    expect(retried.status).to eq(200)
    expect(Entry.find(entry_id).note).to eq("Edited")
    expect(OutboxSnapshot.where(id: entry_id).pluck(:source, :note)).to eq([["manual", "Edited"]])
    expect(IdempotencyReceipt.count).to eq(before[:idempotency_receipts] + 1)
  end

  # The check runs on the row as it will be committed, so a write that fixes the bad field is the repair route.
  it "publishes an update that repairs a stored bad source to a valid one" do
    Entry.find(entry_id).update_column(:source, "legacy")

    outcome = described_class.new.call(build_entry_command(:update, token: owner_token, entry_id:,
                                                                     body: { "source" => "manual" }))

    expect(outcome.status).to eq(200)
    expect(Entry.find(entry_id).source).to eq("manual")
    expect(OutboxSnapshot.where(id: entry_id).pluck(:source)).to eq(["manual"])
  end

  def metadata_nested_97_levels
    97.times.reduce("leaf") { |value, _| { "child" => value } }
  end

  it "refuses destroy and bulk delete of an entry whose stored metadata nests 97 levels, leaving it kept" do
    Entry.find(entry_id).update_column(:source_metadata, metadata_nested_97_levels)
    before = entry_write_counts
    refusal = [409, { "reason" => "unpublishable_entry",
                      "entries" => [{ "entry_id" => entry_id, "fields" => ["source_metadata"] }] }]

    destroyed = described_class.new.call(build_entry_command(:destroy, token: owner_token, entry_id:))
    bulk = described_class.new.call(build_entry_command(:bulk_delete, token: owner_token,
                                                                      body: { "entry_ids" => [entry_id] }))

    expect([destroyed.status, JSON.parse(destroyed.body)]).to eq(refusal)
    expect([bulk.status, JSON.parse(bulk.body)]).to eq(refusal)
    expect(Entry.find(entry_id).discarded_at).to be_nil
    expect(entry_write_counts).to eq(before)
  end

  it "refuses a bulk move of an entry whose stored metadata nests 97 levels, leaving it on its project" do
    other_project = timekeeping_arrange.project(company:)
    Entry.find(entry_id).update_column(:proof_metadata, metadata_nested_97_levels)
    before = entry_write_counts

    moved = described_class.new.call(build_entry_command(:bulk_move, token: owner_token,
                                                                     body: { "entry_ids" => [entry_id], "project_id" => other_project }))

    expect([moved.status, JSON.parse(moved.body)]).to eq(
      [409, { "reason" => "unpublishable_entry", "entries" => [{ "entry_id" => entry_id, "fields" => ["proof_metadata"] }] }]
    )
    expect(Entry.find(entry_id).project_id).to eq(project)
    expect(entry_write_counts).to eq(before)
  end
end
