# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "create against a detach with an uncommitted receipt", committed_data: true do
  let(:company) { create(:company) }
  let(:employee) { create(:user) }
  let(:project) { create(:project, client: create(:client, company:)) }
  let!(:user_actor) { described_class::Actor.user(user_id: employee.id, role: "employee") }
  let!(:detach_actor) do
    described_class::Actor.service(name: "agent-destroy", company_id: company.id, operations: ["agents.detach_entries"])
  end

  before do
    TimekeepingOwnership.current.update!(owner: "monolith", monolith_store: "prepared", handoff_step: nil)
    create(:employment, company:, user: employee)
    employee.add_role("employee", company)
  end

  # Created after the employment above: an agent's user must belong to its company.
  let!(:agent) { create(:agent, company:, user: employee) }
  let!(:generation) { TimekeepingOwnership.current.generation }

  # Local create_entry and update_entry that name an agent take the (company, "agent", agent_id) lock and refuse
  # when the agent is detached, and a test shows such a write cannot land just after a local detach_entries.
  it "AE4: a create naming an agent waits on a detach whose receipt is inserted but uncommitted, then is refused not_found and writes nothing" do
    step = described_class::STEPS.find { |candidate| candidate == :receipt_written }
    entered = Queue.new
    release = Queue.new
    detach_pids = Queue.new
    create_pids = Queue.new
    pause = lambda do |reached|
      next unless reached == step

      entered << true
      release.pop
    end

    detach = committed_data_thread(detach_pids) do
      described_class.call(operation: :detach_entries, company_id: company.id, generation: generation.to_s,
                           actor: detach_actor, params: { "agent_id" => agent.id, "operation_id" => SecureRandom.uuid },
                           checkpoint: pause)
    end
    expect(entered.pop(timeout: 5)).to be(true), "the detach never paused after inserting its receipt"

    create_thread = committed_data_thread(create_pids) do
      described_class.call(
        operation: :create, company_id: company.id, generation: generation.to_s, actor: user_actor,
        params: { "idempotency_key" => "create-in-flight-detach",
                  "body" => { "work_date" => Date.current.iso8601, "duration" => 30.0, "project_id" => project.id,
                              "agent_id" => agent.id } }
      )
    end

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
    expect(described_class::AuditRow.where(company_id: company.id).count).to eq(0)
    expect(described_class::Receipt.where(company_id: company.id, actor_type: "user").count).to eq(0)
  ensure
    release&.push(true)
    [detach, create_thread].compact.each { |thread| thread.join(5) }
  end
end

RSpec.describe Timekeeping::LocalOwner, "create held before the agent lock against a committed detach", committed_data: true do
  let(:company) { create(:company) }
  let(:employee) { create(:user) }
  let(:project) { create(:project, client: create(:client, company:)) }
  let!(:user_actor) { described_class::Actor.user(user_id: employee.id, role: "employee") }
  let!(:detach_actor) do
    described_class::Actor.service(name: "agent-destroy", company_id: company.id, operations: ["agents.detach_entries"])
  end

  before do
    TimekeepingOwnership.current.update!(owner: "monolith", monolith_store: "prepared", handoff_step: nil)
    create(:employment, company:, user: employee)
    employee.add_role("employee", company)
  end

  # Created after the employment above: an agent's user must belong to its company.
  let!(:agent) { create(:agent, company:, user: employee) }
  let!(:generation) { TimekeepingOwnership.current.generation }

  # Local create_entry and update_entry that name an agent take the (company, "agent", agent_id) lock and refuse
  # when the agent is detached, and a test shows such a write cannot land just after a local detach_entries.
  it "AE2: a create naming an agent paused before the agent lock is refused not_found after a detach of that agent commits" do
    step = described_class::STEPS.find { |candidate| candidate == :receipt_key_locked }
    entered = Queue.new
    release = Queue.new
    pause = lambda do |reached|
      next unless reached == step

      entered << true
      release.pop
    end

    create_thread = committed_data_thread do
      described_class.call(
        operation: :create, company_id: company.id, generation: generation.to_s, actor: user_actor,
        params: { "idempotency_key" => "create-before-agent-lock",
                  "body" => { "work_date" => Date.current.iso8601, "duration" => 30.0, "project_id" => project.id,
                              "agent_id" => agent.id } },
        checkpoint: pause
      )
    end
    expect(entered.pop(timeout: 5)).to be(true), "the create never paused before taking the agent lock"

    begin
      detached = described_class.call(operation: :detach_entries, company_id: company.id, generation: generation.to_s,
                                      actor: detach_actor,
                                      params: { "agent_id" => agent.id, "operation_id" => SecureRandom.uuid })
    ensure
      release << true
    end

    expect(detached.status).to eq(200)
    outcome = create_thread.join(10)&.value
    expect([outcome&.status, outcome&.body]).to eq([404, { "reason" => "not_found" }])
    expect(Timekeeping::LocalEntry.where(company_id: company.id).count).to eq(0)
    expect(described_class::AuditRow.where(company_id: company.id).count).to eq(0)
    expect(described_class::Receipt.where(company_id: company.id, actor_type: "user").count).to eq(0)
  ensure
    release&.push(true)
    create_thread&.join(5)
  end
end

RSpec.describe Timekeeping::LocalOwner, "detach against a create that holds the agent lock", committed_data: true do
  let(:company) { create(:company) }
  let(:employee) { create(:user) }
  let(:project) { create(:project, client: create(:client, company:)) }
  let!(:user_actor) { described_class::Actor.user(user_id: employee.id, role: "employee") }
  let!(:detach_actor) do
    described_class::Actor.service(name: "agent-destroy", company_id: company.id, operations: ["agents.detach_entries"])
  end

  before do
    TimekeepingOwnership.current.update!(owner: "monolith", monolith_store: "prepared", handoff_step: nil)
    create(:employment, company:, user: employee)
    employee.add_role("employee", company)
  end

  # Created after the employment above: an agent's user must belong to its company.
  let!(:agent) { create(:agent, company:, user: employee) }
  let!(:generation) { TimekeepingOwnership.current.generation }

  # Local create_entry and update_entry that name an agent take the (company, "agent", agent_id) lock and refuse
  # when the agent is detached, and a test shows such a write cannot land just after a local detach_entries.
  it "AE1: a detach waits on a create holding the agent lock and then detaches the committed entry" do
    step = described_class::STEPS.find { |candidate| candidate == :project_checked }
    entered = Queue.new
    release = Queue.new
    create_pids = Queue.new
    detach_pids = Queue.new
    pause = lambda do |reached|
      next unless reached == step

      entered << true
      release.pop
    end

    create_thread = committed_data_thread(create_pids) do
      described_class.call(
        operation: :create, company_id: company.id, generation: generation.to_s, actor: user_actor,
        params: { "idempotency_key" => "create-holding-agent-lock",
                  "body" => { "work_date" => Date.current.iso8601, "duration" => 30.0, "project_id" => project.id,
                              "agent_id" => agent.id } },
        checkpoint: pause
      )
    end
    expect(entered.pop(timeout: 5)).to be(true), "the create never paused while holding the agent lock"

    detach = committed_data_thread(detach_pids) do
      described_class.call(operation: :detach_entries, company_id: company.id, generation: generation.to_s,
                           actor: detach_actor, params: { "agent_id" => agent.id, "operation_id" => SecureRandom.uuid })
    end

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
    [create_thread, detach].compact.each { |thread| thread.join(5) }
  end
end

RSpec.describe Timekeeping::LocalOwner, "update naming an agent against a committed detach", committed_data: true do
  let(:company) { create(:company) }
  let(:employee) { create(:user) }
  let(:project) { create(:project, client: create(:client, company:)) }
  let!(:user_actor) { described_class::Actor.user(user_id: employee.id, role: "employee") }
  let!(:detach_actor) do
    described_class::Actor.service(name: "agent-destroy", company_id: company.id, operations: ["agents.detach_entries"])
  end

  before do
    TimekeepingOwnership.current.update!(owner: "monolith", monolith_store: "prepared", handoff_step: nil)
    create(:employment, company:, user: employee)
    employee.add_role("employee", company)
  end

  # Created after the employment above: an agent's user must belong to its company.
  let!(:agent) { create(:agent, company:, user: employee) }
  let!(:generation) { TimekeepingOwnership.current.generation }

  # Local create_entry and update_entry that name an agent take the (company, "agent", agent_id) lock and refuse
  # when the agent is detached, and a test shows such a write cannot land just after a local detach_entries.
  it "update naming an agent in its body, paused before the agent lock, is refused not_found after a detach commits and the entry keeps no agent" do
    entry = Timekeeping::LocalEntry.create!(
      company_id: company.id, user_id: employee.id, project_id: project.id, work_date: Date.current,
      duration: 30.0, note: "before", bill_status: "unbilled"
    )
    step = described_class::STEPS.find { |candidate| candidate == :receipt_key_locked }
    entered = Queue.new
    release = Queue.new
    pause = lambda do |reached|
      next unless reached == step

      entered << true
      release.pop
    end

    update_thread = committed_data_thread do
      described_class.call(
        operation: :update, company_id: company.id, generation: generation.to_s, actor: user_actor,
        params: { "idempotency_key" => "update-before-agent-lock", "entry_id" => entry.id,
                  "body" => { "agent_id" => agent.id } },
        checkpoint: pause
      )
    end
    expect(entered.pop(timeout: 5)).to be(true), "the update never paused before taking the agent lock"

    begin
      detached = described_class.call(operation: :detach_entries, company_id: company.id, generation: generation.to_s,
                                      actor: detach_actor,
                                      params: { "agent_id" => agent.id, "operation_id" => SecureRandom.uuid })
    ensure
      release << true
    end

    expect(detached.status).to eq(200)
    outcome = update_thread.join(10)&.value
    expect([outcome&.status, outcome&.body]).to eq([404, { "reason" => "not_found" }])
    entry.reload
    expect([entry.agent_id, entry.version]).to eq([nil, 1])
    expect(described_class::Receipt.where(company_id: company.id, actor_type: "user").count).to eq(0)
  ensure
    release&.push(true)
    update_thread&.join(5)
  end
end

RSpec.describe Timekeeping::LocalOwner, "create after an older detach of a surviving agent", committed_data: true do
  let(:company) { create(:company) }
  let(:employee) { create(:user) }
  let(:project) { create(:project, client: create(:client, company:)) }
  let!(:user_actor) { described_class::Actor.user(user_id: employee.id, role: "employee") }
  let!(:detach_actor) do
    described_class::Actor.service(name: "agent-destroy", company_id: company.id, operations: ["agents.detach_entries"])
  end

  before do
    TimekeepingOwnership.current.update!(owner: "monolith", monolith_store: "prepared", handoff_step: nil)
    create(:employment, company:, user: employee)
    employee.add_role("employee", company)
  end

  # Created after the employment above: an agent's user must belong to its company.
  let!(:agent) { create(:agent, company:, user: employee) }
  let!(:generation) { TimekeepingOwnership.current.generation }

  # A detach that committed before the write began must not refuse it while the agent still exists;
  # otherwise every later write naming the agent would be refused for good.
  it "AE3: a create started after a committed detach of a surviving agent is accepted and keeps the agent" do
    detached = described_class.call(operation: :detach_entries, company_id: company.id, generation: generation.to_s,
                                    actor: detach_actor,
                                    params: { "agent_id" => agent.id, "operation_id" => SecureRandom.uuid })
    expect(detached.status).to eq(200)

    created = described_class.call(
      operation: :create, company_id: company.id, generation: generation.to_s, actor: user_actor,
      params: { "idempotency_key" => "create-after-old-detach",
                "body" => { "work_date" => Date.current.iso8601, "duration" => 30.0, "project_id" => project.id,
                            "agent_id" => agent.id } }
    )

    expect(created.status).to eq(201)
    expect(created.body.fetch("agent_id")).to eq(agent.id)
    expect(Timekeeping::LocalEntry.find(created.body.fetch("id")).agent_id).to eq(agent.id)
  end
end

RSpec.describe Timekeeping::LocalOwner, "agent writes against a detach in another company", committed_data: true do
  let(:company) { create(:company) }
  let(:other_company) { create(:company) }
  let(:employee) { create(:user) }
  let(:project) { create(:project, client: create(:client, company:)) }
  let(:agent) { create(:agent, company:, user: employee) }
  let!(:actor) { described_class::Actor.user(user_id: employee.id, role: "employee") }

  before do
    TimekeepingOwnership.current.update!(owner: "monolith", monolith_store: "prepared", handoff_step: nil)
    create(:employment, company:, user: employee)
    employee.add_role("employee", company)
  end

  let!(:generation) { TimekeepingOwnership.current.generation }

  # "Local create_entry and update_entry that name an agent take the (company, "agent", agent_id) lock and refuse when the agent is detached, and a test shows such a write cannot land just after a local detach_entries."
  # The detach marker is the receipt stored under the detaching company, so only
  # a detach in the writing company may refuse the write.
  it "a detach of the agent id run under another company does not refuse an in-flight create, while one run under the writing company does" do
    expect(described_class::STEPS).to include(:receipt_key_locked)
    agent_id = agent.id

    create_with_agent = lambda do |key, checkpoint|
      described_class.call(
        operation: :create, company_id: company.id, generation: generation.to_s, actor:, checkpoint:,
        params: { "idempotency_key" => key,
                  "body" => { "project_id" => project.id, "work_date" => Date.current.iso8601, "duration" => 60.0,
                              "note" => "with agent", "agent_id" => agent_id,
                              "source" => "manual", "source_metadata" => {} } }
      )
    end
    detach_under = lambda do |detaching_company|
      service = described_class::Actor.service(name: "agent-destroy", company_id: detaching_company.id,
                                               operations: ["agents.detach_entries"])
      described_class.call(
        operation: :detach_entries, company_id: detaching_company.id, generation: generation.to_s, actor: service,
        params: { "agent_id" => agent_id, "operation_id" => SecureRandom.uuid }
      )
    end
    # Pauses the create after it has begun and before it takes the agent lock,
    # lets the detach commit, then releases the create.
    race = lambda do |key, detaching_company|
      entered = Queue.new
      release = Queue.new
      checkpoint = lambda do |step|
        next unless step == :receipt_key_locked

        entered << true
        release.pop
      end
      writer = committed_data_thread(Queue.new) { create_with_agent.call(key, checkpoint) }
      begin
        expect(entered.pop(timeout: 5)).to be(true), "the create never paused before its agent lock"
        detach = committed_data_thread(Queue.new) { detach_under.call(detaching_company) }
        expect(detach.join(10)&.value&.status).to eq(200)
      ensure
        release << true
      end
      writer.join(10)&.value
    end

    foreign = race.call("foreign-company-detach", other_company)
    expect(foreign.status).to eq(201)
    expect(Timekeeping::LocalEntry.where(company_id: company.id).pluck(:agent_id)).to eq([agent_id])

    entries_before = Timekeeping::LocalEntry.where(company_id: company.id).count
    own = race.call("own-company-detach", company)
    expect(own.status).to eq(404)
    expect(own.body).to eq("reason" => "not_found")
    expect(Timekeeping::LocalEntry.where(company_id: company.id).count).to eq(entries_before)
    expect(Timekeeping::LocalEntry.where(company_id: company.id).pluck(:agent_id)).to eq([nil])
  end
end

RSpec.describe Timekeeping::LocalOwner, "create against an uncommitted local detach", committed_data: true do
  let(:company) { create(:company) }
  let(:employee) { create(:user) }
  let(:project) { create(:project, client: create(:client, company:)) }
  let!(:actor) { described_class::Actor.user(user_id: employee.id, role: "employee") }

  before do
    TimekeepingOwnership.current.update!(owner: "monolith", monolith_store: "prepared", handoff_step: nil)
    create(:employment, company:, user: employee)
    employee.add_role("employee", company)
  end

  let!(:agent) { create(:agent, company:, user: employee) }
  let!(:generation) { TimekeepingOwnership.current.generation }

  def uncommitted_detach_create(key, checkpoint: ->(_step) { })
    described_class.call(
      operation: :create, company_id: company.id, generation: generation.to_s, actor:, checkpoint:,
      params: { "idempotency_key" => key, "body" => { "work_date" => Date.current.iso8601, "duration" => 30.0,
                                                      "project_id" => project.id, "agent_id" => agent.id } }
    )
  end

  def uncommitted_detach_run(checkpoint: ->(_step) { })
    service = described_class::Actor.service(name: "agent-destroy", company_id: company.id,
                                             operations: ["agents.detach_entries"])
    described_class.call(operation: :detach_entries, company_id: company.id, generation: generation.to_s,
                         actor: service, params: { "agent_id" => agent.id, "operation_id" => SecureRandom.uuid },
                         checkpoint:)
  end

  def uncommitted_detach_count(table)
    ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM #{table}").to_i
  end

  # Local create_entry and update_entry that name an agent take the (company, "agent", agent_id) lock and
  # refuse when the agent is detached, and a test shows such a write cannot land just after a local
  # detach_entries.
  it "refuses a create naming the agent that waited on a detach whose receipt was inserted but not yet committed" do
    expect(described_class::STEPS).to include(:receipt_written)
    entered = Queue.new
    release = Queue.new
    detach_pids = Queue.new
    create_pids = Queue.new
    hold = lambda do |reached|
      next unless reached == :receipt_written

      entered << true
      release.pop
    end

    detach = committed_data_thread(detach_pids) { uncommitted_detach_run(checkpoint: hold) }
    expect(entered.pop(timeout: 5)).to be(true), "the detach never paused after inserting its receipt"

    create = committed_data_thread(create_pids) { uncommitted_detach_create("in-flight-detach") }

    begin
      blocked = blocked_by?(create_pids.pop(timeout: 5), detach_pids.pop(timeout: 5))
    ensure
      release << true
    end

    expect(blocked).to be(true), "the create never waited on the detach's agent lock"
    expect(detach.join(5)&.value&.status).to eq(200)
    outcome = create.join(5)&.value
    expect([outcome&.status, outcome&.body]).to eq([404, { "reason" => "not_found" }])
    expect(Timekeeping::LocalEntry.where(company_id: company.id).count).to eq(0)
    expect(uncommitted_detach_count("entry_audits")).to eq(0)
    expect(uncommitted_detach_count("entry_outbox_items")).to eq(0)
    expect(described_class::Receipt.where(actor_type: "user").count).to eq(0)
  ensure
    release&.push(true)
    [detach, create].compact.each { |thread| thread.join(5) }
  end
end

RSpec.describe Timekeeping::LocalOwner, "create begun before a committed local detach", committed_data: true do
  let(:company) { create(:company) }
  let(:employee) { create(:user) }
  let(:project) { create(:project, client: create(:client, company:)) }
  let!(:actor) { described_class::Actor.user(user_id: employee.id, role: "employee") }

  before do
    TimekeepingOwnership.current.update!(owner: "monolith", monolith_store: "prepared", handoff_step: nil)
    create(:employment, company:, user: employee)
    employee.add_role("employee", company)
  end

  let!(:agent) { create(:agent, company:, user: employee) }
  let!(:generation) { TimekeepingOwnership.current.generation }

  def begun_before_create(key, checkpoint: ->(_step) { })
    described_class.call(
      operation: :create, company_id: company.id, generation: generation.to_s, actor:, checkpoint:,
      params: { "idempotency_key" => key, "body" => { "work_date" => Date.current.iso8601, "duration" => 30.0,
                                                      "project_id" => project.id, "agent_id" => agent.id } }
    )
  end

  def begun_before_detach
    service = described_class::Actor.service(name: "agent-destroy", company_id: company.id,
                                             operations: ["agents.detach_entries"])
    described_class.call(operation: :detach_entries, company_id: company.id, generation: generation.to_s,
                         actor: service, params: { "agent_id" => agent.id, "operation_id" => SecureRandom.uuid })
  end

  def begun_before_count(table)
    ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM #{table}").to_i
  end

  # Local create_entry and update_entry that name an agent take the (company, "agent", agent_id) lock and
  # refuse when the agent is detached, and a test shows such a write cannot land just after a local
  # detach_entries.
  it "refuses a create naming the agent that began before a local detach committed and took the agent lock after it" do
    expect(described_class::STEPS).to include(:receipt_key_locked)
    entered = Queue.new
    release = Queue.new
    hold = lambda do |reached|
      next unless reached == :receipt_key_locked

      entered << true
      release.pop
    end

    create = committed_data_thread { begun_before_create("begun-before-detach", checkpoint: hold) }
    expect(entered.pop(timeout: 5)).to be(true), "the create never paused after its receipt-key lock"

    begin
      detached = begun_before_detach
    ensure
      release << true
    end

    expect(detached.status).to eq(200)
    outcome = create.join(5)&.value
    expect([outcome&.status, outcome&.body]).to eq([404, { "reason" => "not_found" }])
    expect(Timekeeping::LocalEntry.where(company_id: company.id).count).to eq(0)
    expect(begun_before_count("entry_audits")).to eq(0)
    expect(begun_before_count("entry_outbox_items")).to eq(0)
    expect(described_class::Receipt.where(actor_type: "user").count).to eq(0)
  ensure
    release&.push(true)
    create&.join(5)
  end
end

RSpec.describe Timekeeping::LocalOwner, "local detach behind a create holding the agent lock", committed_data: true do
  let(:company) { create(:company) }
  let(:employee) { create(:user) }
  let(:project) { create(:project, client: create(:client, company:)) }
  let!(:actor) { described_class::Actor.user(user_id: employee.id, role: "employee") }

  before do
    TimekeepingOwnership.current.update!(owner: "monolith", monolith_store: "prepared", handoff_step: nil)
    create(:employment, company:, user: employee)
    employee.add_role("employee", company)
  end

  let!(:agent) { create(:agent, company:, user: employee) }
  let!(:generation) { TimekeepingOwnership.current.generation }

  def lock_holder_create(key, checkpoint: ->(_step) { })
    described_class.call(
      operation: :create, company_id: company.id, generation: generation.to_s, actor:, checkpoint:,
      params: { "idempotency_key" => key, "body" => { "work_date" => Date.current.iso8601, "duration" => 30.0,
                                                      "project_id" => project.id, "agent_id" => agent.id } }
    )
  end

  def lock_holder_detach
    service = described_class::Actor.service(name: "agent-destroy", company_id: company.id,
                                             operations: ["agents.detach_entries"])
    described_class.call(operation: :detach_entries, company_id: company.id, generation: generation.to_s,
                         actor: service, params: { "agent_id" => agent.id, "operation_id" => SecureRandom.uuid })
  end

  # Local create_entry and update_entry that name an agent take the (company, "agent", agent_id) lock and
  # refuse when the agent is detached, and a test shows such a write cannot land just after a local
  # detach_entries.
  it "makes a local detach wait on a create holding the agent lock and then detaches the created entry" do
    expect(described_class::STEPS).to include(:project_checked)
    entered = Queue.new
    release = Queue.new
    create_pids = Queue.new
    detach_pids = Queue.new
    hold = lambda do |reached|
      next unless reached == :project_checked

      entered << true
      release.pop
    end

    create = committed_data_thread(create_pids) { lock_holder_create("holds-agent-lock", checkpoint: hold) }
    expect(entered.pop(timeout: 5)).to be(true), "the create never paused after its project check"

    detach = committed_data_thread(detach_pids) { lock_holder_detach }

    begin
      blocked = blocked_by?(detach_pids.pop(timeout: 5), create_pids.pop(timeout: 5))
    ensure
      release << true
    end

    expect(blocked).to be(true), "the detach never waited on the create's agent lock"
    created = create.join(5)&.value
    expect(created&.status).to eq(201)
    detached = detach.join(5)&.value
    expect([detached&.status, detached&.body]).to eq([200, { "detached" => 1 }])
    entry = Timekeeping::LocalEntry.find_by!(company_id: company.id)
    expect(entry.agent_id).to be_nil
    expect(described_class::AuditRow.where(entry_id: entry.id, action: "detach_entries").count).to eq(1)
  ensure
    release&.push(true)
    [create, detach].compact.each { |thread| thread.join(5) }
  end
end

RSpec.describe Timekeeping::LocalOwner, "update naming the agent begun before a local detach", committed_data: true do
  let(:company) { create(:company) }
  let(:employee) { create(:user) }
  let(:project) { create(:project, client: create(:client, company:)) }
  let!(:actor) { described_class::Actor.user(user_id: employee.id, role: "employee") }

  before do
    TimekeepingOwnership.current.update!(owner: "monolith", monolith_store: "prepared", handoff_step: nil)
    create(:employment, company:, user: employee)
    employee.add_role("employee", company)
  end

  let!(:agent) { create(:agent, company:, user: employee) }
  let!(:generation) { TimekeepingOwnership.current.generation }

  def update_race_detach
    service = described_class::Actor.service(name: "agent-destroy", company_id: company.id,
                                             operations: ["agents.detach_entries"])
    described_class.call(operation: :detach_entries, company_id: company.id, generation: generation.to_s,
                         actor: service, params: { "agent_id" => agent.id, "operation_id" => SecureRandom.uuid })
  end

  # Local create_entry and update_entry that name an agent take the (company, "agent", agent_id) lock and
  # refuse when the agent is detached, and a test shows such a write cannot land just after a local
  # detach_entries.
  it "refuses an update naming the agent in its body that began before a local detach committed" do
    entry = Timekeeping::LocalEntry.create!(
      company_id: company.id, user_id: employee.id, project_id: project.id, work_date: Date.current,
      duration: 30.0, note: "before", bill_status: "unbilled", agent_id: agent.id
    )
    entered = Queue.new
    release = Queue.new
    hold = lambda do |reached|
      next unless reached == :receipt_key_locked

      entered << true
      release.pop
    end

    update = committed_data_thread do
      described_class.call(
        operation: :update, company_id: company.id, generation: generation.to_s, actor:, checkpoint: hold,
        params: { "idempotency_key" => "update-names-agent", "entry_id" => entry.id,
                  "body" => { "note" => "after", "agent_id" => agent.id } }
      )
    end
    expect(entered.pop(timeout: 5)).to be(true), "the update never paused after its receipt-key lock"

    begin
      detached = update_race_detach
    ensure
      release << true
    end

    expect([detached.status, detached.body]).to eq([200, { "detached" => 1 }])
    outcome = update.join(5)&.value
    expect([outcome&.status, outcome&.body]).to eq([404, { "reason" => "not_found" }])
    entry.reload
    expect([entry.agent_id, entry.note]).to eq([nil, "before"])
    expect(described_class::Receipt.where(actor_type: "user").count).to eq(0)
  ensure
    release&.push(true)
    update&.join(5)
  end
end

RSpec.describe Timekeeping::LocalOwner, "writes after an older committed local detach", committed_data: true do
  let(:company) { create(:company) }
  let(:other_company) { create(:company) }
  let(:employee) { create(:user) }
  let(:project) { create(:project, client: create(:client, company:)) }
  let!(:actor) { described_class::Actor.user(user_id: employee.id, role: "employee") }

  before do
    TimekeepingOwnership.current.update!(owner: "monolith", monolith_store: "prepared", handoff_step: nil)
    create(:employment, company:, user: employee)
    employee.add_role("employee", company)
  end

  let!(:agent) { create(:agent, company:, user: employee) }
  let!(:generation) { TimekeepingOwnership.current.generation }

  def older_detach_create(key, agent_id)
    described_class.call(
      operation: :create, company_id: company.id, generation: generation.to_s, actor:,
      params: { "idempotency_key" => key, "body" => { "work_date" => Date.current.iso8601, "duration" => 30.0,
                                                      "project_id" => project.id, "agent_id" => agent_id } }
    )
  end

  def older_detach_run(detach_company)
    service = described_class::Actor.service(name: "agent-destroy", company_id: detach_company.id,
                                             operations: ["agents.detach_entries"])
    described_class.call(operation: :detach_entries, company_id: detach_company.id, generation: generation.to_s,
                         actor: service, params: { "agent_id" => agent.id, "operation_id" => SecureRandom.uuid })
  end

  # Only a detach that commits after a write began refuses it: a detach that committed earlier, of an
  # agent that still exists, would otherwise refuse every later write for that agent forever.
  it "accepts a fresh create naming a surviving agent after an older committed detach, and a nil agent create, and ignores another company's detach" do
    expect(older_detach_run(other_company).status).to eq(200)
    across = older_detach_create("after-other-company-detach", agent.id)
    expect(across.status).to eq(201)
    expect(across.body["agent_id"]).to eq(agent.id)

    expect(older_detach_run(company).status).to eq(200)
    later = older_detach_create("after-older-detach", agent.id)
    expect(later.status).to eq(201)
    expect(later.body["agent_id"]).to eq(agent.id)

    unassigned = older_detach_create("no-agent-after-detach", nil)
    expect(unassigned.status).to eq(201)
    expect(unassigned.body["agent_id"]).to be_nil
    expect(Timekeeping::LocalEntry.where(company_id: company.id, agent_id: agent.id).count).to eq(1)
  end
end

RSpec.describe Timekeeping::LocalOwner, "update naming an agent against a local detach", committed_data: true do
  let(:company) { create(:company) }
  let(:employee) { create(:user) }
  let(:project) { create(:project, client: create(:client, company:)) }
  let(:agent) { create(:agent, company:, user: employee) }
  let!(:user_actor) { described_class::Actor.user(user_id: employee.id, role: "employee") }

  before do
    TimekeepingOwnership.current.update!(owner: "monolith", monolith_store: "prepared", handoff_step: nil)
    create(:employment, company:, user: employee)
    employee.add_role("employee", company)
  end

  let!(:generation) { TimekeepingOwnership.current.generation }

  # Acceptance criterion: "Local create_entry and update_entry that name an
  # agent take the (company, "agent", agent_id) lock and refuse when the agent
  # is detached, and a test shows such a write cannot land just after a local
  # detach_entries."
  # The update pauses after its project check, before it locks the entry row,
  # so the only lock it holds that a detach could wait on is the agent lock.
  it "makes a local detach wait on an update naming the agent in its body while the update holds the agent lock" do
    entry = Timekeeping::LocalEntry.create!(
      company_id: company.id, user_id: employee.id, project_id: project.id, work_date: Date.current,
      duration: 30.0, note: "before", bill_status: "unbilled"
    )
    agent_id = agent.id
    detach_actor = described_class::Actor.service(name: "agent-destroy", company_id: company.id,
                                                  operations: ["agents.detach_entries"])
    entered = Queue.new
    release = Queue.new
    update_pids = Queue.new
    detach_pids = Queue.new
    checkpoint = lambda do |step|
      next unless step == described_class::STEPS.find { |name| name == :project_checked }

      entered << true
      release.pop
    end

    update = committed_data_thread(update_pids) do
      described_class.call(
        operation: :update, company_id: company.id, generation: generation.to_s, actor: user_actor,
        params: { "idempotency_key" => "update-names-agent", "entry_id" => entry.id,
                  "body" => { "agent_id" => agent_id } },
        checkpoint:
      )
    end
    expect(entered.pop(timeout: 5)).to be(true), "the update never reached its project check"

    detach = committed_data_thread(detach_pids) do
      described_class.call(operation: :detach_entries, company_id: company.id, generation: generation.to_s,
                           actor: detach_actor,
                           params: { "agent_id" => agent_id, "operation_id" => SecureRandom.uuid })
    end

    begin
      blocked = blocked_by?(detach_pids.pop(timeout: 5), update_pids.pop(timeout: 5))
    ensure
      release << true
    end

    expect(blocked).to be(true), "the detach never waited on the update's agent lock"
    expect(update.join(5)&.value&.status).to eq(200)
    detached = detach.join(5)&.value
    expect([detached&.status, detached&.body]).to eq([200, { "detached" => 1 }])
    expect(entry.reload.agent_id).to be_nil
    expect(Timekeeping::LocalOwner::AuditRow.where(entry_id: entry.id, action: "detach_entries").count).to eq(1)
  ensure
    release&.push(true)
    [update, detach].compact.each { |thread| thread.join(5) }
  end
end

RSpec.describe Timekeeping::LocalOwner, "agent race with a detach receipt not yet committed", committed_data: true do
  let(:company) { create(:company) }
  let(:employee) { create(:user) }
  let(:project) { create(:project, client: create(:client, company:)) }
  let(:agent) { create(:agent, company:, user: employee) }
  let!(:user_actor) { described_class::Actor.user(user_id: employee.id, role: "employee") }

  before do
    TimekeepingOwnership.current.update!(owner: "monolith", monolith_store: "prepared", handoff_step: nil)
    create(:employment, company:, user: employee)
    employee.add_role("employee", company)
  end

  let!(:generation) { TimekeepingOwnership.current.generation }

  def in_flight_pause(step_name, entered, release)
    step = described_class::STEPS.find { |candidate| candidate == step_name }
    raise ArgumentError, "#{step_name} is not a LocalOwner step" if step.nil?

    lambda do |reached|
      next unless reached == step

      entered << true
      release.pop
    end
  end

  # The receipt is inserted before this pause and committed only after it,
  # so a fence read while the detach is paused would already count it as old.
  # "Local create_entry and update_entry that name an agent take the (company, "agent", agent_id) lock and refuse when the agent is detached, and a test shows such a write cannot land just after a local detach_entries."
  it "AE4: a create naming an agent that starts while a detach of it has inserted but not committed its receipt waits on the agent lock and is refused not_found" do
    entered = Queue.new
    release = Queue.new
    detach_pids = Queue.new
    create_pids = Queue.new
    detach_actor = described_class::Actor.service(name: "agent-destroy", company_id: company.id,
                                                  operations: ["agents.detach_entries"])

    detach = committed_data_thread(detach_pids) do
      described_class.call(
        operation: :detach_entries, company_id: company.id, generation: generation.to_s, actor: detach_actor,
        params: { "agent_id" => agent.id, "operation_id" => SecureRandom.uuid },
        checkpoint: in_flight_pause(:receipt_written, entered, release)
      )
    end
    expect(entered.pop(timeout: 5)).to be(true), "the detach never paused after inserting its receipt"

    create_write = committed_data_thread(create_pids) do
      described_class.call(
        operation: :create, company_id: company.id, generation: generation.to_s, actor: user_actor,
        params: { "idempotency_key" => "in-flight-detach",
                  "body" => { "work_date" => Date.current.iso8601, "duration" => 30, "project_id" => project.id,
                              "agent_id" => agent.id } }
      )
    end

    begin
      blocked = blocked_by?(create_pids.pop(timeout: 5), detach_pids.pop(timeout: 5))
    ensure
      release << true
    end

    expect(blocked).to be(true), "the create never waited on the detach's agent lock"
    expect(detach.join(5)&.value&.status).to eq(200)
    outcome = create_write.join(5)&.value
    expect([outcome&.status, outcome&.body]).to eq([404, { "reason" => "not_found" }])
    expect(Timekeeping::LocalEntry.where(company_id: company.id).count).to eq(0)
    expect(Timekeeping::LocalOutboxEntry.count).to eq(0)
    expect(described_class::AuditRow.where(action: "create").count).to eq(0)
    expect(described_class::Receipt.where(actor_type: "user").count).to eq(0)
  ensure
    release&.push(true)
    [detach, create_write].compact.each { |thread| thread.join(5) }
  end
end

RSpec.describe Timekeeping::LocalOwner, "agent race with a create held before the agent lock", committed_data: true do
  let(:company) { create(:company) }
  let(:employee) { create(:user) }
  let(:project) { create(:project, client: create(:client, company:)) }
  let(:agent) { create(:agent, company:, user: employee) }
  let!(:user_actor) { described_class::Actor.user(user_id: employee.id, role: "employee") }

  before do
    TimekeepingOwnership.current.update!(owner: "monolith", monolith_store: "prepared", handoff_step: nil)
    create(:employment, company:, user: employee)
    employee.add_role("employee", company)
  end

  let!(:generation) { TimekeepingOwnership.current.generation }

  def held_create_pause(step_name, entered, release)
    step = described_class::STEPS.find { |candidate| candidate == step_name }
    raise ArgumentError, "#{step_name} is not a LocalOwner step" if step.nil?

    lambda do |reached|
      next unless reached == step

      entered << true
      release.pop
    end
  end

  # "Local create_entry and update_entry that name an agent take the (company, "agent", agent_id) lock and refuse when the agent is detached, and a test shows such a write cannot land just after a local detach_entries."
  it "AE2: a create naming an agent held before the agent lock while a detach of it commits is refused not_found and writes nothing" do
    entered = Queue.new
    release = Queue.new
    create_write = committed_data_thread do
      described_class.call(
        operation: :create, company_id: company.id, generation: generation.to_s, actor: user_actor,
        params: { "idempotency_key" => "held-before-lock",
                  "body" => { "work_date" => Date.current.iso8601, "duration" => 30, "project_id" => project.id,
                              "agent_id" => agent.id } },
        checkpoint: held_create_pause(:receipt_key_locked, entered, release)
      )
    end
    expect(entered.pop(timeout: 5)).to be(true), "the create never paused after its receipt-key lock"

    detach_actor = described_class::Actor.service(name: "agent-destroy", company_id: company.id,
                                                  operations: ["agents.detach_entries"])
    detach = nil
    begin
      detach = committed_data_thread do
        described_class.call(operation: :detach_entries, company_id: company.id, generation: generation.to_s,
                             actor: detach_actor, params: { "agent_id" => agent.id, "operation_id" => SecureRandom.uuid })
      end
      detached = detach.join(5)&.value
    ensure
      release << true
    end

    expect(detached&.status).to eq(200)
    outcome = create_write.join(5)&.value
    expect([outcome&.status, outcome&.body]).to eq([404, { "reason" => "not_found" }])
    expect(Timekeeping::LocalEntry.where(company_id: company.id, agent_id: agent.id).count).to eq(0)
    expect(Timekeeping::LocalEntry.where(company_id: company.id).count).to eq(0)
    expect(Timekeeping::LocalOutboxEntry.count).to eq(0)
    expect(described_class::Receipt.where(actor_type: "user").count).to eq(0)
  ensure
    release&.push(true)
    [create_write, detach].compact.each { |thread| thread.join(5) }
  end
end

RSpec.describe Timekeeping::LocalOwner, "agent detach markers that are older than the write", committed_data: true do
  let(:company) { create(:company) }
  let(:employee) { create(:user) }
  let(:project) { create(:project, client: create(:client, company:)) }
  let(:agent) { create(:agent, company:, user: employee) }
  let!(:user_actor) { described_class::Actor.user(user_id: employee.id, role: "employee") }

  before do
    TimekeepingOwnership.current.update!(owner: "monolith", monolith_store: "prepared", handoff_step: nil)
    create(:employment, company:, user: employee)
    employee.add_role("employee", company)
  end

  let!(:generation) { TimekeepingOwnership.current.generation }

  def older_marker_detach
    actor = described_class::Actor.service(name: "agent-destroy", company_id: company.id,
                                           operations: ["agents.detach_entries"])
    described_class.call(operation: :detach_entries, company_id: company.id, generation: generation.to_s, actor:,
                         params: { "agent_id" => agent.id, "operation_id" => SecureRandom.uuid })
  end

  def older_marker_create
    described_class.call(
      operation: :create, company_id: company.id, generation: generation.to_s, actor: user_actor,
      params: { "idempotency_key" => "after-old-detach",
                "body" => { "work_date" => Date.current.iso8601, "duration" => 30, "project_id" => project.id,
                            "agent_id" => agent.id } }
    )
  end

  # Refusing on any detach receipt ever stored would refuse every later write
  # for an agent that still exists, and would turn a retry of a write that
  # already committed into a refusal instead of replaying its stored answer.
  it "AE3: a create naming a surviving agent after an older committed detach is accepted, and its retry after a second detach replays 201" do
    expect(older_marker_detach.status).to eq(200)

    first = older_marker_create
    expect(first.status).to eq(201)
    expect(first.body["agent_id"]).to eq(agent.id)

    expect(older_marker_detach.status).to eq(200)
    retried = older_marker_create
    expect([retried.status, retried.body]).to eq([first.status, first.body])
    expect(Timekeeping::LocalEntry.where(company_id: company.id).count).to eq(1)
    expect(described_class::Receipt.where(actor_type: "user").count).to eq(1)
  end
end

RSpec.describe Timekeeping::LocalOwner, "agent race with an update held before the agent lock", committed_data: true do
  let(:company) { create(:company) }
  let(:employee) { create(:user) }
  let(:project) { create(:project, client: create(:client, company:)) }
  let(:agent) { create(:agent, company:, user: employee) }
  let!(:user_actor) { described_class::Actor.user(user_id: employee.id, role: "employee") }

  before do
    TimekeepingOwnership.current.update!(owner: "monolith", monolith_store: "prepared", handoff_step: nil)
    create(:employment, company:, user: employee)
    employee.add_role("employee", company)
  end

  let!(:generation) { TimekeepingOwnership.current.generation }

  def held_update_pause(step_name, entered, release)
    step = described_class::STEPS.find { |candidate| candidate == step_name }
    raise ArgumentError, "#{step_name} is not a LocalOwner step" if step.nil?

    lambda do |reached|
      next unless reached == step

      entered << true
      release.pop
    end
  end

  # "Local create_entry and update_entry that name an agent take the (company, "agent", agent_id) lock and refuse when the agent is detached, and a test shows such a write cannot land just after a local detach_entries."
  it "an update naming the agent held before the agent lock while a detach of it commits is refused not_found and the row keeps agent_id nil" do
    entry = Timekeeping::LocalEntry.create!(
      company_id: company.id, user_id: employee.id, project_id: project.id, work_date: Date.current,
      duration: 30.0, note: "before", bill_status: "unbilled", agent_id: agent.id
    )
    entered = Queue.new
    release = Queue.new
    update_write = committed_data_thread do
      described_class.call(
        operation: :update, company_id: company.id, generation: generation.to_s, actor: user_actor,
        params: { "idempotency_key" => "update-held", "entry_id" => entry.id,
                  "body" => { "note" => "after", "agent_id" => agent.id } },
        checkpoint: held_update_pause(:receipt_key_locked, entered, release)
      )
    end
    expect(entered.pop(timeout: 5)).to be(true), "the update never paused after its receipt-key lock"

    detach_actor = described_class::Actor.service(name: "agent-destroy", company_id: company.id,
                                                  operations: ["agents.detach_entries"])
    detach = nil
    begin
      detach = committed_data_thread do
        described_class.call(operation: :detach_entries, company_id: company.id, generation: generation.to_s,
                             actor: detach_actor, params: { "agent_id" => agent.id, "operation_id" => SecureRandom.uuid })
      end
      detached = detach.join(5)&.value
    ensure
      release << true
    end

    expect([detached&.status, detached&.body]).to eq([200, { "detached" => 1 }])
    outcome = update_write.join(5)&.value
    expect([outcome&.status, outcome&.body]).to eq([404, { "reason" => "not_found" }])
    entry.reload
    expect([entry.agent_id, entry.note]).to eq([nil, "before"])
    expect(described_class::Receipt.where(actor_type: "user").count).to eq(0)
  ensure
    release&.push(true)
    [update_write, detach].compact.each { |thread| thread.join(5) }
  end
end

RSpec.describe Timekeeping::LocalOwner, "agent detach markers of another company", committed_data: true do
  let(:company) { create(:company) }
  let(:other_company) { create(:company) }
  let(:employee) { create(:user) }
  let(:project) { create(:project, client: create(:client, company:)) }
  let(:agent) { create(:agent, company:, user: employee) }
  let!(:user_actor) { described_class::Actor.user(user_id: employee.id, role: "employee") }

  before do
    TimekeepingOwnership.current.update!(owner: "monolith", monolith_store: "prepared", handoff_step: nil)
    create(:employment, company:, user: employee)
    employee.add_role("employee", company)
  end

  let!(:generation) { TimekeepingOwnership.current.generation }

  def other_company_create(checkpoint)
    described_class.call(
      operation: :create, company_id: company.id, generation: generation.to_s, actor: user_actor,
      params: { "idempotency_key" => "other-company-marker",
                "body" => { "work_date" => Date.current.iso8601, "duration" => 30, "project_id" => project.id,
                            "agent_id" => agent.id } },
      checkpoint:
    )
  end

  # The detach runs in another company while this company's create has begun,
  # so a marker lookup without the company filter would see a newer receipt.
  it "a detach of the same agent id stored under another company does not refuse a create naming the agent here" do
    other_actor = described_class::Actor.service(name: "agent-destroy", company_id: other_company.id,
                                                 operations: ["agents.detach_entries"])
    detach_elsewhere = lambda do |reached|
      next unless reached == described_class::STEPS.find { |step| step == :receipt_key_locked }

      outcome = committed_data_thread do
        described_class.call(operation: :detach_entries, company_id: other_company.id, generation: generation.to_s,
                             actor: other_actor, params: { "agent_id" => agent.id, "operation_id" => SecureRandom.uuid })
      end.join(5)&.value
      raise "the other company's detach did not commit" unless outcome&.status == 200
    end

    created = other_company_create(detach_elsewhere)

    expect(created.status).to eq(201)
    expect(Timekeeping::LocalEntry.where(company_id: company.id).pluck(:agent_id)).to eq([agent.id])
  end
end

RSpec.describe Timekeeping::LocalOwner, "create holding the agent lock", committed_data: true do
  let(:company) { create(:company) }
  let(:employee) { create(:user) }
  let(:project) { create(:project, client: create(:client, company:)) }
  let(:agent) { create(:agent, company:, user: employee) }
  let!(:actor) { described_class::Actor.user(user_id: employee.id, role: "employee") }

  before do
    TimekeepingOwnership.current.update!(owner: "monolith", monolith_store: "prepared", handoff_step: nil)
    create(:employment, company:, user: employee)
    employee.add_role("employee", company)
  end

  let!(:generation) { TimekeepingOwnership.current.generation }

  # "Local create_entry and update_entry that name an agent take the (company, "agent", agent_id) lock and refuse when the agent is detached, and a test shows such a write cannot land just after a local detach_entries."
  # The scenario this defeats: a create that never takes the lock lets a
  # second session take the agent lock at once, so nothing orders the two.
  it "a session taking lock_agent for the agent waits on a create naming that agent until the create commits" do
    entered = Queue.new
    release = Queue.new
    create_pids = Queue.new
    locker_pids = Queue.new
    step = described_class::STEPS.find { |name| name == :project_checked }
    checkpoint = lambda do |reached|
      next unless reached == step

      entered << true
      release.pop
    end

    writer = committed_data_thread(create_pids) do
      described_class.call(
        operation: :create, company_id: company.id, generation: generation.to_s, actor:, checkpoint:,
        params: { "idempotency_key" => SecureRandom.uuid,
                  "body" => { "work_date" => Date.current.iso8601, "duration" => 30.0,
                              "project_id" => project.id, "agent_id" => agent.id } }
      )
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
    [writer, locker].compact.each { |thread| thread.join(5) }
  end
end
