# frozen_string_literal: true

require "rails_helper"

# Local create_entry and update_entry that name an agent take the (company, "agent", agent_id) lock and refuse
# when the agent is detached, and a test shows such a write cannot land just after a local detach_entries.
#
# Two connections race a local entry write against a local detach_entries of the same agent. Each example pauses
# one transaction at a LocalOwner step, proves the other session waits with blocked_by? where a wait is expected,
# then releases and checks the answers and the committed rows.
RSpec.describe Timekeeping::LocalOwner, "entry writes naming an agent against a local detach", committed_data: true do
  let(:company) { create(:company) }
  let(:other_company) { create(:company) }
  let(:employee) { create(:user) }
  let(:project) { create(:project, client: create(:client, company:)) }
  let!(:user_actor) { described_class::Actor.user(user_id: employee.id, role: "employee") }

  before do
    # The committed-data reset leaves ownership with the legacy store, which
    # LocalOwner refuses as stale_generation.
    TimekeepingOwnership.current.update!(owner: "monolith", monolith_store: "prepared", handoff_step: nil)
    create(:employment, company:, user: employee)
    employee.add_role("employee", company)
  end

  # Created after the employment above: an agent's user must belong to its company.
  let!(:agent) { create(:agent, company:, user: employee) }
  let!(:generation) { TimekeepingOwnership.current.generation }

  # The step is taken from LocalOwner::STEPS, so renaming it fails here
  # instead of leaving a pause that never fires.
  def agent_race_pause(step_name, entered, release)
    step = described_class::STEPS.find { |candidate| candidate == step_name }
    raise ArgumentError, "#{step_name} is not a LocalOwner step" if step.nil?

    lambda do |reached|
      next unless reached == step

      entered << true
      release.pop
    end
  end

  def agent_race_create(key, agent_id: agent.id, checkpoint: ->(_step) { })
    described_class.call(
      operation: :create, company_id: company.id, generation: generation.to_s, actor: user_actor, checkpoint:,
      params: { "idempotency_key" => key, "body" => { "work_date" => Date.current.iso8601, "duration" => 30.0,
                                                      "project_id" => project.id, "agent_id" => agent_id } }
    )
  end

  def agent_race_update(key, entry, body, checkpoint: ->(_step) { })
    described_class.call(
      operation: :update, company_id: company.id, generation: generation.to_s, actor: user_actor, checkpoint:,
      params: { "idempotency_key" => key, "entry_id" => entry.id, "body" => body }
    )
  end

  def agent_race_detach(detaching_company = company, checkpoint: ->(_step) { })
    service = described_class::Actor.service(name: "agent-destroy", company_id: detaching_company.id,
                                             operations: ["agents.detach_entries"])
    described_class.call(operation: :detach_entries, company_id: detaching_company.id, generation: generation.to_s,
                         actor: service, params: { "agent_id" => agent.id, "operation_id" => SecureRandom.uuid },
                         checkpoint:)
  end

  def agent_race_entry(agent_id: nil)
    Timekeeping::LocalEntry.create!(
      company_id: company.id, user_id: employee.id, project_id: project.id, work_date: Date.current,
      duration: 30.0, note: "before", bill_status: "unbilled", agent_id:
    )
  end

  def agent_race_count(table)
    ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM #{table}").to_i
  end

  # Joins each worker and kills one still running after the wait, so no open
  # transaction outlives the example and blocks the committed-data reset.
  def agent_race_stop(*threads)
    threads.compact.each { |thread| thread.join(5) || thread.kill.join(5) }
  end

  # The receipt is inserted before this pause and committed only after it,
  # so a fence read while the detach is paused would already count it as old.
  it "AE4: a create naming an agent waits on a detach whose receipt is inserted but uncommitted, then is refused not_found and writes nothing" do
    entered = Queue.new
    release = Queue.new
    detach_pids = Queue.new
    create_pids = Queue.new

    detach = committed_data_thread(detach_pids) do
      agent_race_detach(checkpoint: agent_race_pause(:receipt_written, entered, release))
    end
    expect(entered.pop(timeout: 5)).to be(true), "the detach never paused after inserting its receipt"

    create_thread = committed_data_thread(create_pids) { agent_race_create("create-in-flight-detach") }

    begin
      blocked = blocked_by?(create_pids.pop(timeout: 5), detach_pids.pop(timeout: 5))
    ensure
      release << true
    end

    expect(blocked).to be(true), "the create never waited on the detach's agent lock"
    expect(detach.join(10)&.value&.status).to eq(200)
    outcome = create_thread.join(10)&.value
    expect([outcome&.status, outcome&.body]).to eq([404, { "reason" => "not_found" }])
    expect(Timekeeping::LocalEntry.where(company_id: company.id).count).to eq(0)
    expect(agent_race_count("entry_audits")).to eq(0)
    expect(agent_race_count("entry_outbox_items")).to eq(0)
    expect(described_class::Receipt.where(actor_type: "user").count).to eq(0)
  ensure
    release&.push(true)
    agent_race_stop(detach, create_thread)
  end

  it "AE2: a create naming an agent paused before the agent lock is refused not_found after a detach of that agent commits" do
    entered = Queue.new
    release = Queue.new
    create_thread = committed_data_thread do
      agent_race_create("create-before-agent-lock",
                        checkpoint: agent_race_pause(:receipt_key_locked, entered, release))
    end
    expect(entered.pop(timeout: 5)).to be(true), "the create never paused before taking the agent lock"

    begin
      detached = agent_race_detach
    ensure
      release << true
    end

    expect(detached.status).to eq(200)
    outcome = create_thread.join(10)&.value
    expect([outcome&.status, outcome&.body]).to eq([404, { "reason" => "not_found" }])
    expect(Timekeeping::LocalEntry.where(company_id: company.id).count).to eq(0)
    expect(agent_race_count("entry_audits")).to eq(0)
    expect(agent_race_count("entry_outbox_items")).to eq(0)
    expect(described_class::Receipt.where(actor_type: "user").count).to eq(0)
  ensure
    release&.push(true)
    agent_race_stop(create_thread)
  end

  it "AE1: a detach waits on a create holding the agent lock and then detaches the committed entry" do
    entered = Queue.new
    release = Queue.new
    create_pids = Queue.new
    detach_pids = Queue.new

    create_thread = committed_data_thread(create_pids) do
      agent_race_create("create-holding-agent-lock", checkpoint: agent_race_pause(:project_checked, entered, release))
    end
    expect(entered.pop(timeout: 5)).to be(true), "the create never paused while holding the agent lock"

    detach = committed_data_thread(detach_pids) { agent_race_detach }

    begin
      blocked = blocked_by?(detach_pids.pop(timeout: 5), create_pids.pop(timeout: 5))
    ensure
      release << true
    end

    expect(blocked).to be(true), "the detach never waited on the create's agent lock"
    created = create_thread.join(10)&.value
    expect(created&.status).to eq(201)
    detached = detach.join(10)&.value
    expect([detached&.status, detached&.body]).to eq([200, { "detached" => 1 }])
    entry = Timekeeping::LocalEntry.find(created.body.fetch("id"))
    expect(entry.agent_id).to be_nil
    expect(described_class::AuditRow.where(entry_id: entry.id, action: "detach_entries").count).to eq(1)
  ensure
    release&.push(true)
    agent_race_stop(create_thread, detach)
  end

  it "update naming an agent in its body, paused before the agent lock, is refused not_found after a detach commits and the entry keeps no agent" do
    entry = agent_race_entry
    attributes_before = entry.reload.attributes
    entered = Queue.new
    release = Queue.new
    update_thread = committed_data_thread do
      agent_race_update("update-before-agent-lock", entry, { "agent_id" => agent.id },
                        checkpoint: agent_race_pause(:receipt_key_locked, entered, release))
    end
    expect(entered.pop(timeout: 5)).to be(true), "the update never paused before taking the agent lock"

    begin
      detached = agent_race_detach
    ensure
      release << true
    end

    expect(detached.status).to eq(200)
    outcome = update_thread.join(10)&.value
    expect([outcome&.status, outcome&.body]).to eq([404, { "reason" => "not_found" }])
    expect(entry.reload.attributes).to eq(attributes_before)
    expect([entry.agent_id, entry.version]).to eq([nil, 1])
    expect(described_class::Receipt.where(actor_type: "user").count).to eq(0)
  ensure
    release&.push(true)
    agent_race_stop(update_thread)
  end

  it "an update naming the agent held before the agent lock while a detach of it commits is refused not_found and the row keeps agent_id nil" do
    entry = agent_race_entry(agent_id: agent.id)
    entered = Queue.new
    release = Queue.new
    update_thread = committed_data_thread do
      agent_race_update("update-held", entry, { "note" => "after", "agent_id" => agent.id },
                        checkpoint: agent_race_pause(:receipt_key_locked, entered, release))
    end
    expect(entered.pop(timeout: 5)).to be(true), "the update never paused after its receipt-key lock"

    begin
      detached = agent_race_detach
    ensure
      release << true
    end

    expect([detached.status, detached.body]).to eq([200, { "detached" => 1 }])
    outcome = update_thread.join(10)&.value
    expect([outcome&.status, outcome&.body]).to eq([404, { "reason" => "not_found" }])
    entry.reload
    expect([entry.agent_id, entry.note]).to eq([nil, "before"])
    expect(described_class::Receipt.where(actor_type: "user").count).to eq(0)
  ensure
    release&.push(true)
    agent_race_stop(update_thread)
  end

  # The update pauses after its project check, before it locks the entry row,
  # so the only lock it holds that a detach could wait on is the agent lock.
  it "makes a local detach wait on an update naming the agent in its body while the update holds the agent lock" do
    entry = agent_race_entry
    entered = Queue.new
    release = Queue.new
    update_pids = Queue.new
    detach_pids = Queue.new

    update_thread = committed_data_thread(update_pids) do
      agent_race_update("update-names-agent", entry, { "agent_id" => agent.id },
                        checkpoint: agent_race_pause(:project_checked, entered, release))
    end
    expect(entered.pop(timeout: 5)).to be(true), "the update never reached its project check"

    detach = committed_data_thread(detach_pids) { agent_race_detach }

    begin
      blocked = blocked_by?(detach_pids.pop(timeout: 5), update_pids.pop(timeout: 5))
    ensure
      release << true
    end

    expect(blocked).to be(true), "the detach never waited on the update's agent lock"
    expect(update_thread.join(5)&.value&.status).to eq(200)
    detached = detach.join(5)&.value
    expect([detached&.status, detached&.body]).to eq([200, { "detached" => 1 }])
    expect(entry.reload.agent_id).to be_nil
    expect(described_class::AuditRow.where(entry_id: entry.id, action: "detach_entries").count).to eq(1)
  ensure
    release&.push(true)
    agent_race_stop(update_thread, detach)
  end

  # Refusing on any detach receipt ever stored would refuse every later write
  # for an agent that still exists, and would turn a retry of a write that
  # already committed into a refusal instead of replaying its stored answer.
  it "AE3: a create naming a surviving agent after an older committed detach is accepted, and its retry after a second detach replays 201" do
    expect(agent_race_detach.status).to eq(200)

    first = agent_race_create("after-old-detach")
    expect(first.status).to eq(201)
    expect(first.body["agent_id"]).to eq(agent.id)

    # The retry has begun when the second detach commits, so that detach is
    # newer than its marker: only replaying the receipt first answers 201.
    entered = Queue.new
    release = Queue.new
    retry_thread = committed_data_thread do
      agent_race_create("after-old-detach", checkpoint: agent_race_pause(:receipt_key_locked, entered, release))
    end
    expect(entered.pop(timeout: 5)).to be(true), "the retry never paused before taking the agent lock"
    begin
      second_detach = agent_race_detach
    ensure
      release << true
    end

    expect(second_detach.status).to eq(200)
    retried = retry_thread.join(10)&.value
    expect([retried&.status, retried&.body]).to eq([first.status, first.body])
    expect(Timekeeping::LocalEntry.where(company_id: company.id).count).to eq(1)
    expect(described_class::Receipt.where(actor_type: "user").count).to eq(1)
  ensure
    release&.push(true)
    agent_race_stop(retry_thread)
  end

  # The detach marker is the newest detach receipt stored under the writing company that committed before the
  # write began. So only a detach in the writing company that commits after the write began may refuse it: one
  # run under another company must not, and neither may an older one, or every later write for an agent that
  # still exists would be refused. The in-flight rows differ only in the detaching company. A paused create has
  # not taken the agent lock yet, so no row waits on a lock and only the committed detach receipt decides it.
  it "refuses a create naming an agent only for a detach in its own company that commits after the create began" do
    create_after_detach = {
      committed_before: lambda do |key, detaching_company|
        expect(agent_race_detach(detaching_company).status).to eq(200)
        agent_race_create(key)
      end,
      # Pauses the create after it has begun and before it takes the agent
      # lock, lets the detach commit, then releases the create.
      in_flight: lambda do |key, detaching_company|
        entered = Queue.new
        release = Queue.new
        checkpoint = agent_race_pause(:receipt_key_locked, entered, release)
        writer = committed_data_thread(Queue.new) { agent_race_create(key, checkpoint:) }
        detach = nil
        begin
          expect(entered.pop(timeout: 5)).to be(true), "the create never paused before its agent lock"
          detach = committed_data_thread(Queue.new) { agent_race_detach(detaching_company) }
          expect(detach.join(10)&.value&.status).to eq(200)
        ensure
          release << true
        end
        writer.join(10)&.value
      ensure
        agent_race_stop(writer, detach)
      end
    }
    rows = [
      { name: "another company's detach while the create is in flight", detaching_company: other_company,
        timing: :in_flight, accepted: true },
      { name: "an older committed detach in the writing company", detaching_company: company,
        timing: :committed_before, accepted: true },
      { name: "a detach in the writing company while the create is in flight", detaching_company: company,
        timing: :in_flight, accepted: false }
    ]

    rows.each_with_index do |row, index|
      entries_before = Timekeeping::LocalEntry.where(company_id: company.id).count
      user_receipts_before = described_class::Receipt.where(actor_type: "user").count

      outcome = create_after_detach.fetch(row[:timing]).call("marker-row-#{index}", row[:detaching_company])

      if row[:accepted]
        expect([outcome&.status, outcome&.body&.dig("agent_id")]).to eq([201, agent.id]), row[:name]
        expect(Timekeeping::LocalEntry.find(outcome.body.fetch("id")).agent_id).to eq(agent.id), row[:name]
        expect(Timekeeping::LocalEntry.where(company_id: company.id).count).to eq(entries_before + 1), row[:name]
        expect(described_class::Receipt.where(actor_type: "user").count).to eq(user_receipts_before + 1), row[:name]
      else
        expect([outcome&.status, outcome&.body]).to eq([404, { "reason" => "not_found" }]), row[:name]
        expect(outcome.body.to_json).not_to include("agent-destroy"), row[:name]
        expect(Timekeeping::LocalEntry.where(company_id: company.id).count).to eq(entries_before), row[:name]
        expect(described_class::Receipt.where(actor_type: "user").count).to eq(user_receipts_before), row[:name]
      end
    end
  end

  # The create takes the agent lock before it reads the ownership row FOR
  # SHARE, the order detach-entries uses. Were the order reversed, a create
  # waiting on the agent lock would hold the row, so a handoff would wait
  # behind it, and any holder of the agent lock that then read the row would
  # close a cycle.
  it "a create waiting on the agent lock holds no lock on the ownership row, so a handoff completes while it waits" do
    hold_lock = Queue.new
    release_lock = Queue.new
    locker_pids = Queue.new
    create_pids = Queue.new

    locker = committed_data_thread(locker_pids) do
      ActiveRecord::Base.transaction do
        described_class::ServiceCommands.lock_agent(company.id, agent.id)
        hold_lock << true
        release_lock.pop
      end
    end
    expect(hold_lock.pop(timeout: 5)).to be(true), "the agent lock was never taken"

    create_thread = committed_data_thread(create_pids) { agent_race_create("create-beside-handoff") }
    handoff = nil
    begin
      create_waits = blocked_by?(create_pids.pop(timeout: 5), locker_pids.pop(timeout: 5))
      handoff = committed_data_thread do
        TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID).update_all(handoff_step: "close_admission")
      end
      handoff_done = handoff.join(5)
    ensure
      release_lock << true
    end

    expect(create_waits).to be(true), "the create never waited on the agent lock"
    expect(handoff_done).not_to be_nil, "the handoff waited on the create while the create waited on the agent lock"
    expect(locker.join(10)).not_to be_nil
    outcome = create_thread.join(10)&.value
    expect([outcome&.status, outcome&.body]).to eq([409, { "reason" => "stale_generation" }])
    expect(Timekeeping::LocalEntry.where(company_id: company.id).count).to eq(0)
  ensure
    release_lock&.push(true)
    agent_race_stop(locker, create_thread, handoff)
  end

  # A create that never takes the lock lets a second session take the agent
  # lock at once, so nothing orders the two.
  it "a session taking lock_agent for the agent waits on a create naming that agent until the create commits" do
    entered = Queue.new
    release = Queue.new
    create_pids = Queue.new
    locker_pids = Queue.new

    writer = committed_data_thread(create_pids) do
      agent_race_create(SecureRandom.uuid, checkpoint: agent_race_pause(:project_checked, entered, release))
    end
    expect(entered.pop(timeout: 5)).to be(true), "the create never reached project_checked"

    locker = committed_data_thread(locker_pids) do
      ActiveRecord::Base.transaction { described_class::ServiceCommands.lock_agent(company.id, agent.id) }
    end

    begin
      blocked = blocked_by?(locker_pids.pop(timeout: 5), create_pids.pop(timeout: 5))
    ensure
      release << true
    end

    expect(blocked).to be(true), "a second session took the agent lock while the create naming the agent held it"
    expect(writer.join(5)&.value&.status).to eq(201)
    expect(locker.join(5)).not_to be_nil
  ensure
    release&.push(true)
    agent_race_stop(writer, locker)
  end
end
