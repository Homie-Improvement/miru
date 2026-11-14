# frozen_string_literal: true

require "rails_helper"

# Bounded waits for the examples that hold one session at a lock while another runs.
module LocalOwnerServiceCommandRaceHelpers
  RACE_WAIT_SECONDS = 5

  # Polls the block until it returns a value. A worker that has already died re-raises its error
  # here, and one that never gets there fails the example after RACE_WAIT_SECONDS instead of hanging.
  def await_service_command_worker(worker)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + RACE_WAIT_SECONDS
    until (result = yield)
      worker.value unless worker.alive?
      raise "a race worker did not get there within #{RACE_WAIT_SECONDS} seconds" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
    result
  end

  # Joins each started worker so no connection stays checked out. A worker's own error is left
  # for the example to read through its value, so it does not hide the example's first failure.
  def finish_service_command_workers(*workers)
    workers.compact.each do |worker|
      worker.join(RACE_WAIT_SECONDS)
    rescue StandardError
      nil
    end
  end
end

RSpec.describe Timekeeping::LocalOwner, "service command access refusals" do
  it "refuses nil, user, ungranted and foreign-company callers of mark_billed and detach_entries with 401, 403, 403 and 404 before any lock and with nothing changed" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    other_company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice_id = 501
    agent_id = 77
    billable = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                               work_date: "2026-03-02", duration: 60.0, bill_status: "unbilled")
    ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql_array([<<~SQL.squish, company.id, billable.id, invoice_id, SecureRandom.uuid]))
      INSERT INTO reservations (company_id, entry_id, invoice_id, operation_id, state, disposition, created_at)
      VALUES (?, ?, ?, ?, 'committed', 'active', NOW())
    SQL
    agent_entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                                  work_date: "2026-03-02", duration: 60.0, bill_status: "unbilled",
                                                  agent_id:)
    before = [billable, agent_entry].map { |entry| entry.reload.attributes }
    baseline = timekeeping_row_counts
    actor = described_class::Actor
    targets = { mark_billed: { "invoice_id" => invoice_id }, detach_entries: { "agent_id" => agent_id } }
    # Each command is refused when the caller holds only the other command's operation.
    other_operation = { mark_billed: "agents.detach_entries", detach_entries: "invoices.mark_billed" }
    granted_operation = { mark_billed: "invoices.mark_billed", detach_entries: "agents.detach_entries" }

    targets.each do |operation, target|
      # "A nil actor answers unauthorized, a user actor or a service without the qualified operation (invoices.mark_billed, agents.detach_entries) answers forbidden, and a service bound to another company answers not_found, all with nothing changed"
      callers = {
        nil => [401, "unauthorized"],
        actor.user(user_id: owner.id, role: "owner") => [403, "forbidden"],
        actor.service(name: "invoice-boundary", company_id: company.id, operations: [other_operation.fetch(operation)]) =>
          [403, "forbidden"],
        actor.service(name: "invoice-boundary", company_id: other_company.id,
                      operations: [granted_operation.fetch(operation)]) => [404, "not_found"]
      }

      callers.each do |caller, (status, reason)|
        steps = []
        outcome = described_class.call(
          operation:, company_id: company.id, generation:, actor: caller,
          params: target.merge("operation_id" => SecureRandom.uuid),
          checkpoint: ->(step) { steps << step }
        )

        expect([operation, outcome.status, outcome.body]).to eq([operation, status, { "reason" => reason }])
        # "Use `LocalOwner::ServiceAccess.call(actor:, operation:, company_id:)` from the sibling leaf, before any lock or read."
        expect(steps).to be_empty
        expect(timekeeping_row_counts).to eq(baseline)
        expect([billable, agent_entry].map { |entry| entry.reload.attributes }).to eq(before)
      end
    end
  end
end

RSpec.describe Timekeeping::LocalOwner, "service command receipts across callers" do
  it "never replays a stored mark_billed answer to a refused caller of the same operation_id, and gives another company's service its own receipt" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    other_company = create(:company)
    invoice_id = 501
    reserve = lambda do |owner_company|
      member = timekeeping_member(owner_company, "employee")
      project = create(:project, client: create(:client, company: owner_company))
      entry = Timekeeping::LocalEntry.create!(company_id: owner_company.id, user_id: member.id, project_id: project.id,
                                              work_date: "2026-03-02", duration: 60.0, bill_status: "unbilled")
      ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql_array([<<~SQL.squish, owner_company.id, entry.id, invoice_id, SecureRandom.uuid]))
        INSERT INTO reservations (company_id, entry_id, invoice_id, operation_id, state, disposition, created_at)
        VALUES (?, ?, ?, ?, 'committed', 'active', NOW())
      SQL
      entry
    end
    own_entry = reserve.call(company)
    foreign_entry = reserve.call(other_company)
    operation_id = SecureRandom.uuid
    params = { "invoice_id" => invoice_id, "operation_id" => operation_id }
    actor = described_class::Actor
    granted = actor.service(name: "invoice-boundary", company_id: company.id, operations: ["invoices.mark_billed"])
    call = ->(caller, company_id) { described_class.call(operation: :mark_billed, company_id:, generation:, actor: caller, params:) }

    first = call.call(granted, company.id)
    expect([first.status, first.body]).to eq([200, { "billed" => 1 }])
    baseline = timekeeping_row_counts
    foreign_before = foreign_entry.reload.attributes

    # A caller that access refuses learns nothing of the stored answer, even with the same service name and key.
    ungranted = actor.service(name: "invoice-boundary", company_id: company.id, operations: ["agents.detach_entries"])
    misbound = actor.service(name: "invoice-boundary", company_id: other_company.id, operations: ["invoices.mark_billed"])
    expect([call.call(ungranted, company.id).status, call.call(ungranted, company.id).body]).to eq([403, { "reason" => "forbidden" }])
    expect([call.call(misbound, company.id).status, call.call(misbound, company.id).body]).to eq([404, { "reason" => "not_found" }])
    expect(timekeeping_row_counts).to eq(baseline)
    expect(foreign_entry.reload.attributes).to eq(foreign_before)

    # "The same operation_id from two services, or from two companies, gives separate receipts."
    second = call.call(misbound, other_company.id)
    expect([second.status, second.body]).to eq([200, { "billed" => 1 }])
    expect(foreign_entry.reload.bill_status).to eq("billed")
    expect(own_entry.reload.bill_status).to eq("billed")
    receipts = described_class::Receipt.where(key: operation_id, actor_type: "service", actor_name: "invoice-boundary")
    expect(receipts.pluck(:company_id)).to contain_exactly(company.id, other_company.id)
  end
end

RSpec.describe Timekeeping::LocalOwner, "service command target checks" do
  it "refuses detach_entries with a missing or non-integer agent_id and never touches the company's entries that have no agent" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    member = timekeeping_member(company, "employee")
    project = create(:project, client: create(:client, company:))
    unassigned = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: member.id, project_id: project.id,
                                                 work_date: "2026-03-02", duration: 60.0, bill_status: "unbilled")
    before = unassigned.reload.attributes
    baseline = timekeeping_row_counts
    service = described_class::Actor.service(name: "agent-destroy", company_id: company.id,
                                             operations: ["agents.detach_entries"])

    [{}, { "agent_id" => nil }, { "agent_id" => "" }, { "agent_id" => "77; DROP" }, { "agent_id" => -1 }].each do |target|
      outcome = described_class.call(operation: :detach_entries, company_id: company.id, generation:, actor: service,
                                     params: target.merge("operation_id" => SecureRandom.uuid))

      expect([target, outcome.status, outcome.body]).to eq([target, 400, { "reason" => "invalid_request" }])
      expect(timekeeping_row_counts).to eq(baseline)
      expect(unassigned.reload.attributes).to eq(before)
    end
  end
end

RSpec.describe Timekeeping::LocalOwner do
  # "No app or lib file names LocalOwnerClient or LocalOwnerArrange, and LocalOwner.call has no token parameter"
  it "LocalOwner.call takes no token parameter and answers mark_billed and detach_entries with a nil actor as unauthorized" do
    parameter_names = described_class.method(:call).parameters.map(&:last)
    expect(parameter_names).not_to include(:token, :bearer_token, :authorization, :credential)
    expect(parameter_names).to include(:actor)

    company = create(:company)
    generation = prepare_local_ownership!.generation.to_s
    before = timekeeping_row_counts

    # "A nil actor answers `unauthorized`."
    [[:mark_billed, { "invoice_id" => 501 }], [:detach_entries, { "agent_id" => 77 }]].each do |operation, target|
      outcome = described_class.call(
        operation:, company_id: company.id, generation:, actor: nil,
        params: target.merge("operation_id" => SecureRandom.uuid)
      )

      expect([outcome.status, outcome.body]).to eq([401, { "reason" => "unauthorized" }])
    end
    expect(timekeeping_row_counts).to eq(before)
  end
end

RSpec.describe Timekeeping::LocalOwner, "mark_billed writes" do
  it "mark_billed bills only the two committed entries of the invoice, each with version+1, one audit row and one outbox row, and stores one receipt" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    user = timekeeping_member(company, "employee")
    project = create(:project, client: create(:client, company:))
    new_entry = lambda do
      Timekeeping::LocalEntry.create!(company_id: company.id, user_id: user.id, project_id: project.id,
                                      work_date: "2026-03-02", duration: 60.0, bill_status: "unbilled")
    end
    reserve = lambda do |entry, invoice_id, state|
      ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql_array([<<~SQL.squish, company.id, entry.id, invoice_id, SecureRandom.uuid, state, "active"]))
        INSERT INTO reservations (company_id, entry_id, invoice_id, operation_id, state, disposition, created_at)
        VALUES (?, ?, ?, ?, ?, ?, NOW())
      SQL
    end
    audits_for = lambda do |entry|
      ApplicationRecord.connection.select_value(
        ApplicationRecord.sanitize_sql_array(["SELECT COUNT(*) FROM entry_audits WHERE entry_id = ?", entry.id])
      ).to_i
    end
    x = new_entry.call
    y = new_entry.call
    provisional = new_entry.call
    other_invoice = new_entry.call
    reserve.call(x, 501, "committed")
    reserve.call(y, 501, "committed")
    reserve.call(provisional, 501, "provisional")
    reserve.call(other_invoice, 502, "committed")
    entries = [x, y, provisional, other_invoice]
    versions_before = entries.to_h { |entry| [entry.id, entry.reload.version] }
    audits_before = entries.to_h { |entry| [entry.id, audits_for.call(entry)] }
    counts_before = timekeeping_row_counts
    actor = described_class::Actor.service(name: "invoice-boundary", company_id: company.id,
                                           operations: ["invoices.mark_billed"])

    # "mark_billed bills only the entries the invoice holds by committed reservation, writing version, audit, outbox and receipt in one transaction"
    outcome = described_class.call(operation: :mark_billed, company_id: company.id, generation:, actor:,
                                   params: { "invoice_id" => 501, "operation_id" => SecureRandom.uuid })

    expect(outcome.status).to eq(200)
    expect(outcome.body).to eq("billed" => 2)
    expect(entries.map { |entry| entry.reload.bill_status }).to eq(%w[billed billed unbilled unbilled])
    # "Each changed entry gets version + 1, one `entry_audits` row and one `entry_outbox_items` snapshot under the outbox advisory lock."
    expect(entries.map { |entry| entry.reload.version - versions_before.fetch(entry.id) }).to eq([1, 1, 0, 0])
    expect(entries.map { |entry| audits_for.call(entry) - audits_before.fetch(entry.id) }).to eq([1, 1, 0, 0])
    counts_after = timekeeping_row_counts
    expect(counts_after["entry_audits"] - counts_before["entry_audits"]).to eq(2)
    expect(counts_after["entry_outbox_items"] - counts_before["entry_outbox_items"]).to eq(2)
    expect(counts_after["idempotency_records"] - counts_before["idempotency_records"]).to eq(1)
    expect(counts_after["entries"]).to eq(counts_before["entries"])
  end
end

RSpec.describe Timekeeping::LocalOwner, "detach_entries retries" do
  it "a retry of detach_entries at the current generation replays the first answer with no new rows and no version change, and a stale retry after the stored receipt answers 409 with nothing written" do
    ownership = prepare_local_ownership!
    generation = ownership.generation.to_s
    company = create(:company)
    user = timekeeping_member(company, "employee")
    project = create(:project, client: create(:client, company:))
    entries = Array.new(2) do
      Timekeeping::LocalEntry.create!(company_id: company.id, user_id: user.id, project_id: project.id,
                                      work_date: "2026-03-02", duration: 60.0, bill_status: "unbilled", agent_id: 77)
    end
    actor = described_class::Actor.service(name: "agent-destroy", company_id: company.id,
                                           operations: ["agents.detach_entries"])
    params = { "agent_id" => 77, "operation_id" => SecureRandom.uuid }
    first = described_class.call(operation: :detach_entries, company_id: company.id, generation:, actor:, params:)
    expect(first.status).to eq(200)
    expect(first.body).to eq("detached" => 2)
    counts_after_first = timekeeping_row_counts
    versions_after_first = entries.map { |entry| entry.reload.version }

    # "A retry at the current generation replays the first answer with no new rows."
    replay = described_class.call(operation: :detach_entries, company_id: company.id, generation:, actor:, params:)
    expect([replay.status, replay.body]).to eq([first.status, first.body])
    expect(timekeeping_row_counts).to eq(counts_after_first)
    expect(entries.map { |entry| entry.reload.version }).to eq(versions_after_first)

    # "A stale body generation on mark_billed or detach_entries gives 409 stale_generation and writes nothing, including a retry whose earlier answer is stored"
    ownership.update!(generation: ownership.generation + 1)
    stale = described_class.call(operation: :detach_entries, company_id: company.id, generation:, actor:, params:)
    expect(stale.status).to eq(409)
    expect(stale.body).to eq("reason" => "stale_generation")
    expect(timekeeping_row_counts).to eq(counts_after_first)
    expect(entries.map { |entry| entry.reload.version }).to eq(versions_after_first)
  end
end

RSpec.describe Timekeeping::LocalOwner, "mark_billed rollback at an injected failure" do
  it "a failure injected after the entry write or the outbox write of mark_billed leaves no billed entry, audit, outbox row or receipt, and a later retry still runs" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    user = timekeeping_member(company, "employee")
    project = create(:project, client: create(:client, company:))
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: user.id, project_id: project.id,
                                            work_date: "2026-03-02", duration: 60.0, bill_status: "unbilled")
    ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql_array([<<~SQL.squish, company.id, entry.id, 501, SecureRandom.uuid]))
      INSERT INTO reservations (company_id, entry_id, invoice_id, operation_id, state, disposition, created_at)
      VALUES (?, ?, ?, ?, 'committed', 'active', NOW())
    SQL
    actor = described_class::Actor.service(name: "invoice-boundary", company_id: company.id,
                                           operations: ["invoices.mark_billed"])
    params = { "invoice_id" => 501, "operation_id" => SecureRandom.uuid }
    baseline = timekeeping_row_counts
    entry_before = entry.reload.attributes
    injected = Class.new(StandardError)

    # "A failure injected after the entry write leaves no outbox row or receipt."
    %i[entry_written outbox_written].each do |failing_step|
      expect do
        described_class.call(operation: :mark_billed, company_id: company.id, generation:, actor:, params:,
                             checkpoint: ->(seen) { raise injected if seen == failing_step })
      end.to raise_error(injected)
      expect(timekeeping_row_counts).to eq(baseline)
      expect(entry.reload.attributes).to eq(entry_before)
    end

    # Nothing was stored, so the same key runs as a first attempt.
    outcome = described_class.call(operation: :mark_billed, company_id: company.id, generation:, actor:, params:)
    expect(outcome.body).to eq("billed" => 1)
    expect(entry.reload.bill_status).to eq("billed")
  end
end

RSpec.describe Timekeeping::LocalOwner, "service receipts per service and company" do
  it "one operation_id from two services and from two companies runs each detach_entries and stores separate receipts" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    other_company = create(:company)
    entry_for = lambda do |owner_company, agent_id|
      user = timekeeping_member(owner_company, "employee")
      project = create(:project, client: create(:client, company: owner_company))
      Timekeeping::LocalEntry.create!(company_id: owner_company.id, user_id: user.id, project_id: project.id,
                                      work_date: "2026-03-02", duration: 60.0, bill_status: "unbilled", agent_id:)
    end
    first_entry = entry_for.call(company, 77)
    second_entry = entry_for.call(company, 78)
    foreign_entry = entry_for.call(other_company, 77)
    operation_id = SecureRandom.uuid
    detach = lambda do |owner_company, name, agent_id|
      actor = described_class::Actor.service(name:, company_id: owner_company.id, operations: ["agents.detach_entries"])
      described_class.call(operation: :detach_entries, company_id: owner_company.id, generation:, actor:,
                           params: { "agent_id" => agent_id, "operation_id" => operation_id })
    end
    receipts_before = timekeeping_row_counts["idempotency_records"]

    # "The same operation_id from two services, or from two companies, gives separate receipts."
    expect(detach.call(company, "agent-destroy", 77).body).to eq("detached" => 1)
    expect(detach.call(company, "agent-cleanup", 78).body).to eq("detached" => 1)
    expect(detach.call(other_company, "agent-destroy", 77).body).to eq("detached" => 1)

    expect(timekeeping_row_counts["idempotency_records"] - receipts_before).to eq(3)
    expect([first_entry, second_entry, foreign_entry].map { |entry| entry.reload.agent_id }).to eq([nil, nil, nil])
  end
end

RSpec.describe Timekeeping::LocalOwner, "service command key reuse" do
  it "reusing a detach_entries operation_id for a different agent answers idempotency_key_reused and writes nothing" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    user = timekeeping_member(company, "employee")
    project = create(:project, client: create(:client, company:))
    entry_for = lambda do |agent_id|
      Timekeeping::LocalEntry.create!(company_id: company.id, user_id: user.id, project_id: project.id,
                                      work_date: "2026-03-02", duration: 60.0, bill_status: "unbilled", agent_id:)
    end
    entry_for.call(77)
    other_agent_entry = entry_for.call(78)
    actor = described_class::Actor.service(name: "agent-destroy", company_id: company.id,
                                           operations: ["agents.detach_entries"])
    operation_id = SecureRandom.uuid
    first = described_class.call(operation: :detach_entries, company_id: company.id, generation:, actor:,
                                 params: { "agent_id" => 77, "operation_id" => operation_id })
    expect(first.body).to eq("detached" => 1)
    baseline = timekeeping_row_counts
    other_before = other_agent_entry.reload.attributes

    # "A reused key with a different target answers `idempotency_key_reused`."
    reused = described_class.call(operation: :detach_entries, company_id: company.id, generation:, actor:,
                                  params: { "agent_id" => 78, "operation_id" => operation_id })

    expect(reused.body).to eq("reason" => "idempotency_key_reused")
    expect(reused.status).to eq(described_class::STATUS.fetch(:idempotency_key_reused))
    expect(timekeeping_row_counts).to eq(baseline)
    expect(other_agent_entry.reload.attributes).to eq(other_before)
  end
end

RSpec.describe Timekeeping::LocalOwner, "detach_entries tenant boundary" do
  it "detach_entries clears agent 77 on the caller company's entries and leaves another company's entry with agent 77 untouched" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    other_company = create(:company)
    new_entry = lambda do |owning_company|
      member = timekeeping_member(owning_company, "employee")
      project = create(:project, client: create(:client, company: owning_company))
      Timekeeping::LocalEntry.create!(company_id: owning_company.id, user_id: member.id, project_id: project.id,
                                      work_date: "2026-03-02", duration: 60.0, bill_status: "unbilled", agent_id: 77)
    end
    own_entries = Array.new(2) { new_entry.call(company) }
    foreign_entry = new_entry.call(other_company)
    foreign_before = foreign_entry.reload.attributes
    audits_for = ->(entry) { ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM entry_audits WHERE entry_id = #{entry.id.to_i}").to_i }
    foreign_audits_before = audits_for.call(foreign_entry)
    outbox_before = timekeeping_row_counts["entry_outbox_items"]
    actor = described_class::Actor.service(name: "agent-destroy", company_id: company.id, operations: ["agents.detach_entries"])

    # "detach_entries clears one agent on the caller company's entries only, leaving another company's entries unchanged"
    outcome = described_class.call(operation: :detach_entries, company_id: company.id, generation:, actor:,
                                   params: { "agent_id" => 77, "operation_id" => SecureRandom.uuid })

    expect(outcome.status).to eq(200)
    expect(outcome.body).to eq("detached" => 2)
    expect(own_entries.map { |entry| entry.reload.agent_id }).to eq([nil, nil])
    expect(foreign_entry.reload.attributes).to eq(foreign_before)
    expect(audits_for.call(foreign_entry)).to eq(foreign_audits_before)
    # Only the caller company's two changed entries get an outbox snapshot.
    expect(timekeeping_row_counts["entry_outbox_items"]).to eq(outbox_before + 2)
  end
end

RSpec.describe Timekeeping::LocalOwner, "mark_billed tenant boundary" do
  it "mark_billed bills only the caller company's entries when another company holds a committed reservation for the same invoice number" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    other_company = create(:company)
    invoice_number = 501
    new_entry = lambda do |owning_company|
      member = timekeeping_member(owning_company, "employee")
      project = create(:project, client: create(:client, company: owning_company))
      Timekeeping::LocalEntry.create!(company_id: owning_company.id, user_id: member.id, project_id: project.id,
                                      work_date: "2026-03-02", duration: 60.0, bill_status: "unbilled")
    end
    commit_to_invoice = lambda do |entry|
      ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql_array([<<~SQL.squish, entry.company_id, entry.id, invoice_number, SecureRandom.uuid]))
        INSERT INTO reservations (company_id, entry_id, invoice_id, operation_id, state, disposition, created_at)
        VALUES (?, ?, ?, ?, 'committed', 'active', NOW())
      SQL
    end
    own_entry = new_entry.call(company)
    commit_to_invoice.call(own_entry)
    foreign_entry = new_entry.call(other_company)
    commit_to_invoice.call(foreign_entry)
    foreign_before = foreign_entry.reload.attributes
    actor = described_class::Actor.service(name: "invoice-boundary", company_id: company.id, operations: ["invoices.mark_billed"])

    # "mark_billed bills only the entries the invoice holds by committed reservation, writing version, audit, outbox and receipt in one transaction"
    # "Every local query filters by `company_id`." Invoice numbers repeat across companies, so the
    # other company's committed reservation for 501 must not bill its entry.
    outcome = described_class.call(operation: :mark_billed, company_id: company.id, generation:, actor:,
                                   params: { "invoice_id" => invoice_number, "operation_id" => SecureRandom.uuid })

    expect(outcome.status).to eq(200)
    expect(outcome.body).to eq("billed" => 1)
    expect(own_entry.reload.bill_status).to eq("billed")
    expect(foreign_entry.reload.attributes).to eq(foreign_before)
  end
end

RSpec.describe Timekeeping::LocalOwner, "service commands refuse another company's service" do
  it "a service bound to another company gets not_found on mark_billed and detach_entries, even for an operation_id with a stored receipt, and nothing changes" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    other_company = create(:company)
    member = timekeeping_member(company, "employee")
    project = create(:project, client: create(:client, company:))
    agent_entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: member.id, project_id: project.id,
                                                  work_date: "2026-03-02", duration: 60.0, bill_status: "unbilled", agent_id: 77)
    billable = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: member.id, project_id: project.id,
                                               work_date: "2026-03-02", duration: 60.0, bill_status: "unbilled")
    ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql_array([<<~SQL.squish, company.id, billable.id, 501, SecureRandom.uuid]))
      INSERT INTO reservations (company_id, entry_id, invoice_id, operation_id, state, disposition, created_at)
      VALUES (?, ?, ?, ?, 'committed', 'active', NOW())
    SQL
    operations = %w[invoices.mark_billed agents.detach_entries]
    own_service = described_class::Actor.service(name: "invoice-boundary", company_id: company.id, operations:)
    foreign_service = described_class::Actor.service(name: "invoice-boundary", company_id: other_company.id, operations:)
    commands = {
      mark_billed: { "invoice_id" => 501, "operation_id" => SecureRandom.uuid },
      detach_entries: { "agent_id" => 77, "operation_id" => SecureRandom.uuid }
    }
    # The caller's own company stores a receipt under each operation_id first, so a foreign
    # caller that reached replay would get that stored answer back.
    commands.each do |operation, params|
      expect(described_class.call(operation:, company_id: company.id, generation:, actor: own_service, params:).status).to eq(200)
    end
    baseline = timekeeping_row_counts
    entries_before = [agent_entry, billable].map { |entry| entry.reload.attributes }

    # "A service bound to another company answers `not_found`."
    commands.each do |operation, params|
      steps = []
      outcome = described_class.call(operation:, company_id: company.id, generation:, actor: foreign_service, params:,
                                     checkpoint: ->(step) { steps << step })

      expect([operation, outcome.status, outcome.body]).to eq([operation, 404, { "reason" => "not_found" }])
      expect(steps).to be_empty
    end
    expect(timekeeping_row_counts).to eq(baseline)
    expect([agent_entry, billable].map { |entry| entry.reload.attributes }).to eq(entries_before)
  end
end

RSpec.describe Timekeeping::LocalOwner, "service receipts per company" do
  it "the same operation_id and service name from two companies runs detach_entries in each company with its own receipt" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    other_company = create(:company)
    new_entry = lambda do |owning_company|
      member = timekeeping_member(owning_company, "employee")
      project = create(:project, client: create(:client, company: owning_company))
      Timekeeping::LocalEntry.create!(company_id: owning_company.id, user_id: member.id, project_id: project.id,
                                      work_date: "2026-03-02", duration: 60.0, bill_status: "unbilled", agent_id: 77)
    end
    own_entry = new_entry.call(company)
    foreign_entry = new_entry.call(other_company)
    operation_id = SecureRandom.uuid
    receipts = lambda do |owning_company|
      ActiveRecord::Base.connection.select_value(ActiveRecord::Base.sanitize_sql_array(
        ["SELECT COUNT(*) FROM idempotency_records WHERE company_id = ? AND key = ? AND actor_type = 'service'",
         owning_company.id, operation_id]
      )).to_i
    end
    detach = lambda do |owning_company|
      actor = described_class::Actor.service(name: "agent-destroy", company_id: owning_company.id,
                                             operations: ["agents.detach_entries"])
      described_class.call(operation: :detach_entries, company_id: owning_company.id, generation:, actor:,
                           params: { "agent_id" => 77, "operation_id" => operation_id })
    end

    # "The same operation_id from two services, or from two companies, gives separate receipts."
    first = detach.call(company)
    expect(foreign_entry.reload.agent_id).to eq(77)
    second = detach.call(other_company)

    expect([first.status, first.body]).to eq([200, { "detached" => 1 }])
    # The second company's command runs on its own entry; it is not a replay of the first.
    expect([second.status, second.body]).to eq([200, { "detached" => 1 }])
    expect(own_entry.reload.agent_id).to be_nil
    expect(foreign_entry.reload.agent_id).to be_nil
    expect([receipts.call(company), receipts.call(other_company)]).to eq([1, 1])
  end
end

RSpec.describe Timekeeping::LocalOwner, "mark_billed on committed reservations" do
  def count_rows(table, entry_id)
    ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(["SELECT COUNT(*) FROM #{table} WHERE entry_id = ?", entry_id])
    ).to_i
  end

  it "mark_billed bills the two committed entries, skips a provisional entry and another invoice's entry, and writes version, one audit, one outbox row each and one receipt" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    other_invoice = create(:invoice, company:, client: project.client)
    new_entry = lambda do
      Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                      work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled")
    end
    reserve = lambda do |entry, invoice_id, state|
      ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql_array([<<~SQL.squish, company.id, entry.id, invoice_id, SecureRandom.uuid, state, "active"]))
        INSERT INTO reservations (company_id, entry_id, invoice_id, operation_id, state, disposition, created_at)
        VALUES (?, ?, ?, ?, ?, ?, NOW())
      SQL
    end
    x = new_entry.call
    y = new_entry.call
    provisional = new_entry.call
    elsewhere = new_entry.call
    reserve.call(x, invoice.id, "committed")
    reserve.call(y, invoice.id, "committed")
    reserve.call(provisional, invoice.id, "provisional")
    reserve.call(elsewhere, other_invoice.id, "committed")
    versions = [x, y, provisional, elsewhere].to_h { |entry| [entry.id, entry.reload.version] }
    baseline = timekeeping_row_counts
    actor = described_class::Actor.service(name: "invoice-boundary", company_id: company.id, operations: ["invoices.mark_billed"])

    # "mark_billed bills only the entries the invoice holds by committed reservation, writing version, audit, outbox and receipt in one transaction"
    outcome = described_class.call(operation: :mark_billed, company_id: company.id, generation:, actor:,
                                   params: { "invoice_id" => invoice.id, "operation_id" => SecureRandom.uuid })

    expect(outcome.status).to eq(200)
    expect(outcome.body).to eq("billed" => 2)
    [x, y].each do |entry|
      expect(entry.reload.bill_status).to eq("billed")
      expect(entry.version).to eq(versions.fetch(entry.id) + 1)
      expect(count_rows("entry_audits", entry.id)).to eq(1)
      expect(count_rows("entry_outbox_items", entry.id)).to eq(1)
    end
    [provisional, elsewhere].each do |entry|
      expect(entry.reload.bill_status).to eq("unbilled")
      expect(entry.version).to eq(versions.fetch(entry.id))
      expect(count_rows("entry_audits", entry.id)).to eq(0)
      expect(count_rows("entry_outbox_items", entry.id)).to eq(0)
    end
    expect(timekeeping_row_counts).to eq(
      baseline.merge("entry_audits" => baseline["entry_audits"] + 2, "entry_outbox_items" => baseline["entry_outbox_items"] + 2,
                     "idempotency_records" => baseline["idempotency_records"] + 1)
    )
  end
end

RSpec.describe Timekeeping::LocalOwner, "detach_entries within one company" do
  def count_rows(table, entry_id)
    ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(["SELECT COUNT(*) FROM #{table} WHERE entry_id = ?", entry_id])
    ).to_i
  end

  def agent_entry(company, agent_id)
    member = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    Timekeeping::LocalEntry.create!(company_id: company.id, user_id: member.id, project_id: project.id,
                                    work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled", agent_id:)
  end

  it "detach_entries clears agent 77 on the caller company's entries and leaves the same agent id on a second company's entry untouched" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    other_company = create(:company)
    own = [agent_entry(company, 77), agent_entry(company, 77)]
    other_agent = agent_entry(company, 78)
    foreign = agent_entry(other_company, 77)
    foreign_before = foreign.reload.attributes
    other_agent_before = other_agent.reload.attributes
    own_versions = own.map { |entry| entry.reload.version }
    actor = described_class::Actor.service(name: "agent-destroy", company_id: company.id, operations: ["agents.detach_entries"])

    # "detach_entries clears one agent on the caller company's entries only, leaving another company's entries unchanged"
    outcome = described_class.call(operation: :detach_entries, company_id: company.id, generation:, actor:,
                                   params: { "agent_id" => 77, "operation_id" => SecureRandom.uuid })

    expect(outcome.status).to eq(200)
    expect(outcome.body).to eq("detached" => 2)
    own.each_with_index do |entry, index|
      expect(entry.reload.agent_id).to be_nil
      expect(entry.version).to eq(own_versions[index] + 1)
      expect(count_rows("entry_audits", entry.id)).to eq(1)
      expect(count_rows("entry_outbox_items", entry.id)).to eq(1)
    end
    expect(foreign.reload.attributes).to eq(foreign_before)
    expect(count_rows("entry_audits", foreign.id)).to eq(0)
    expect(count_rows("entry_outbox_items", foreign.id)).to eq(0)
    expect(other_agent.reload.attributes).to eq(other_agent_before)
  end
end

RSpec.describe Timekeeping::LocalOwner, "service command retries" do
  it "a retry at a stale generation after a stored receipt answers 409 stale_generation and writes nothing, while a retry at the current generation replays the first answer with no new rows" do
    generation = prepare_local_ownership!.generation.to_s
    stale = (Integer(generation, 10) - 1).to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    billable = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                               work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled")
    ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql_array([<<~SQL.squish, company.id, billable.id, invoice.id, SecureRandom.uuid]))
      INSERT INTO reservations (company_id, entry_id, invoice_id, operation_id, state, disposition, created_at)
      VALUES (?, ?, ?, ?, 'committed', 'active', NOW())
    SQL
    agent_entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                                  work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled", agent_id: 77)
    actor = described_class::Actor.service(name: "invoice-boundary", company_id: company.id,
                                           operations: ["invoices.mark_billed", "agents.detach_entries"])
    commands = { mark_billed: { "invoice_id" => invoice.id }, detach_entries: { "agent_id" => 77 } }

    commands.each do |operation, target|
      params = target.merge("operation_id" => SecureRandom.uuid)
      first = described_class.call(operation:, company_id: company.id, generation:, actor:, params:)
      expect(first.status).to eq(200)
      baseline = timekeeping_row_counts
      entries_before = [billable, agent_entry].map { |entry| entry.reload.attributes }

      # "A stale body generation on mark_billed or detach_entries gives 409 stale_generation and writes nothing, including a retry whose earlier answer is stored"
      refused = described_class.call(operation:, company_id: company.id, generation: stale, actor:, params:)
      expect([refused.status, refused.body]).to eq([409, { "reason" => "stale_generation" }])
      expect(timekeeping_row_counts).to eq(baseline)
      expect([billable, agent_entry].map { |entry| entry.reload.attributes }).to eq(entries_before)

      # "A retry at the current generation replays the first answer with no new rows."
      replay = described_class.call(operation:, company_id: company.id, generation:, actor:, params:)
      expect([replay.status, replay.body]).to eq([first.status, first.body])
      expect(timekeeping_row_counts).to eq(baseline)
      expect([billable, agent_entry].map { |entry| entry.reload.attributes }).to eq(entries_before)
    end
  end
end

RSpec.describe Timekeeping::LocalOwner, "service command key reuse" do
  it "the same operation_id for a different agent answers idempotency_key_reused and changes nothing" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    first_agent_entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                                        work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled", agent_id: 77)
    second_agent_entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                                         work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled", agent_id: 78)
    actor = described_class::Actor.service(name: "agent-destroy", company_id: company.id, operations: ["agents.detach_entries"])
    operation_id = SecureRandom.uuid

    first = described_class.call(operation: :detach_entries, company_id: company.id, generation:, actor:,
                                 params: { "agent_id" => 77, "operation_id" => operation_id })
    expect(first.body).to eq("detached" => 1)
    expect(first_agent_entry.reload.agent_id).to be_nil
    baseline = timekeeping_row_counts
    second_before = second_agent_entry.reload.attributes

    # "A reused key with a different target answers `idempotency_key_reused`."
    reused = described_class.call(operation: :detach_entries, company_id: company.id, generation:, actor:,
                                  params: { "agent_id" => 78, "operation_id" => operation_id })

    expect(reused.body).to eq("reason" => "idempotency_key_reused")
    expect(reused.status).to eq(described_class::STATUS.fetch(:idempotency_key_reused))
    expect(timekeeping_row_counts).to eq(baseline)
    expect(second_agent_entry.reload.attributes).to eq(second_before)
  end
end

RSpec.describe Timekeeping::LocalOwner, "service receipts per service and company" do
  it "the same operation_id from two services and from two companies gives separate receipts and each command runs" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    other_company = create(:company)
    entry_for = lambda do |owner_company|
      member = timekeeping_member(owner_company, "owner")
      project = create(:project, client: create(:client, company: owner_company))
      Timekeeping::LocalEntry.create!(company_id: owner_company.id, user_id: member.id, project_id: project.id,
                                      work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled", agent_id: 77)
    end
    first_entry = entry_for.call(company)
    foreign_entry = entry_for.call(other_company)
    operation_id = SecureRandom.uuid
    grant = ["agents.detach_entries"]
    receipts = -> { timekeeping_row_counts(%w[idempotency_records]).fetch("idempotency_records") }
    start = receipts.call

    # "The same operation_id from two services, or from two companies, gives separate receipts"
    first = described_class.call(operation: :detach_entries, company_id: company.id, generation:,
                                 actor: described_class::Actor.service(name: "agent-destroy", company_id: company.id, operations: grant),
                                 params: { "agent_id" => 77, "operation_id" => operation_id })
    expect(first.body).to eq("detached" => 1)
    expect(first_entry.reload.agent_id).to be_nil

    second_entry = entry_for.call(company)
    other_service = described_class.call(operation: :detach_entries, company_id: company.id, generation:,
                                         actor: described_class::Actor.service(name: "agent-cleanup", company_id: company.id, operations: grant),
                                         params: { "agent_id" => 77, "operation_id" => operation_id })
    expect(other_service.body).to eq("detached" => 1)
    expect(second_entry.reload.agent_id).to be_nil

    other_company_answer = described_class.call(operation: :detach_entries, company_id: other_company.id, generation:,
                                                actor: described_class::Actor.service(name: "agent-destroy", company_id: other_company.id, operations: grant),
                                                params: { "agent_id" => 77, "operation_id" => operation_id })
    expect(other_company_answer.body).to eq("detached" => 1)
    expect(foreign_entry.reload.agent_id).to be_nil

    expect(receipts.call).to eq(start + 3)
  end
end

RSpec.describe Timekeeping::LocalOwner, "service command callers" do
  it "service commands refuse nil, user, ungranted and other-company callers with 401, 403, 403 and 404 and change nothing" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    other_company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    billable = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                               work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled", agent_id: 77)
    ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql_array([<<~SQL.squish, company.id, billable.id, invoice.id, SecureRandom.uuid]))
      INSERT INTO reservations (company_id, entry_id, invoice_id, operation_id, state, disposition, created_at)
      VALUES (?, ?, ?, ?, 'committed', 'active', NOW())
    SQL
    baseline = timekeeping_row_counts
    entry_before = billable.reload.attributes
    actor = described_class::Actor
    both = ["invoices.mark_billed", "agents.detach_entries"]
    commands = {
      mark_billed: [{ "invoice_id" => invoice.id }, ["agents.detach_entries"]],
      detach_entries: [{ "agent_id" => 77 }, ["invoices.mark_billed"]]
    }

    # "A nil actor answers unauthorized, a user actor or a service without the qualified operation (invoices.mark_billed, agents.detach_entries) answers forbidden, and a service bound to another company answers not_found, all with nothing changed"
    commands.each do |operation, (target, other_grant)|
      callers = {
        nil => [401, "unauthorized"],
        actor.user(user_id: owner.id, role: "owner") => [403, "forbidden"],
        actor.service(name: "invoice-boundary", company_id: company.id, operations: other_grant) => [403, "forbidden"],
        actor.service(name: "invoice-boundary", company_id: other_company.id, operations: both) => [404, "not_found"]
      }
      callers.each do |caller, (status, reason)|
        steps = []
        outcome = described_class.call(operation:, company_id: company.id, generation:, actor: caller,
                                       params: target.merge("operation_id" => SecureRandom.uuid),
                                       checkpoint: ->(step) { steps << step })

        expect([operation, outcome.status, outcome.body]).to eq([operation, status, { "reason" => reason }])
        expect(steps).to be_empty
        expect(timekeeping_row_counts).to eq(baseline)
        expect(billable.reload.attributes).to eq(entry_before)
      end
    end
  end
end

RSpec.describe Timekeeping::LocalOwner, "service command rollback" do
  it "a failure injected at entry_written or outbox_written leaves no entry change, audit, outbox row or receipt" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                            work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled", agent_id: 77)
    ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql_array([<<~SQL.squish, company.id, entry.id, invoice.id, SecureRandom.uuid]))
      INSERT INTO reservations (company_id, entry_id, invoice_id, operation_id, state, disposition, created_at)
      VALUES (?, ?, ?, ?, 'committed', 'active', NOW())
    SQL
    actor = described_class::Actor.service(name: "invoice-boundary", company_id: company.id,
                                           operations: ["invoices.mark_billed", "agents.detach_entries"])
    injected = Class.new(StandardError)
    commands = { mark_billed: { "invoice_id" => invoice.id }, detach_entries: { "agent_id" => 77 } }

    # "A failure injected after the entry write leaves no outbox row or receipt."
    commands.each do |operation, target|
      %i[entry_written outbox_written].each do |step|
        expect(described_class::STEPS).to include(step)
        baseline = timekeeping_row_counts
        entry_before = entry.reload.attributes
        seen_steps = []

        expect {
          described_class.call(operation:, company_id: company.id, generation:, actor:,
                               params: target.merge("operation_id" => SecureRandom.uuid),
                               checkpoint: lambda { |seen|
                                 seen_steps << seen
                                 raise injected if seen == step
                               })
        }.to raise_error(injected)

        expect(seen_steps).to include(step)
        expect(timekeeping_row_counts).to eq(baseline)
        expect(entry.reload.attributes).to eq(entry_before)
      end
    end
  end
end

RSpec.describe Timekeeping::LocalOwner, "service command retries at a stale generation" do
  it "a retry at a stale generation whose earlier answer is stored answers 409 stale_generation on mark_billed and detach_entries and writes nothing" do
    ownership = prepare_local_ownership!
    generation = ownership.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    billable = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                               work_date: "2026-03-02", duration: 60.0, bill_status: "unbilled")
    ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql_array([<<~SQL.squish, company.id, billable.id, 501, SecureRandom.uuid]))
      INSERT INTO reservations (company_id, entry_id, invoice_id, operation_id, state, disposition, created_at)
      VALUES (?, ?, ?, ?, 'committed', 'active', NOW())
    SQL
    Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                    work_date: "2026-03-02", duration: 60.0, bill_status: "unbilled", agent_id: 77)
    actor = described_class::Actor.service(name: "invoice-boundary", company_id: company.id,
                                           operations: %w[invoices.mark_billed agents.detach_entries])
    commands = { mark_billed: { "invoice_id" => 501 }, detach_entries: { "agent_id" => 77 } }
    keys = commands.keys.index_with { SecureRandom.uuid }

    commands.each do |operation, target|
      first = described_class.call(operation:, company_id: company.id, generation:, actor:,
                                   params: target.merge("operation_id" => keys.fetch(operation)))
      expect(first.status).to eq(200)
    end

    ownership.update!(generation: ownership.generation + 1)
    baseline = timekeeping_row_counts
    versions = Timekeeping::LocalEntry.where(company_id: company.id).order(:id).pluck(:id, :version)

    # "A stale body generation on mark_billed or detach_entries gives 409 stale_generation and writes nothing, including a retry whose earlier answer is stored"
    commands.each do |operation, target|
      retry_outcome = described_class.call(operation:, company_id: company.id, generation:, actor:,
                                           params: target.merge("operation_id" => keys.fetch(operation)))
      expect([operation, retry_outcome.status, retry_outcome.body]).to eq([operation, 409, { "reason" => "stale_generation" }])
    end
    expect(timekeeping_row_counts).to eq(baseline)
    expect(Timekeeping::LocalEntry.where(company_id: company.id).order(:id).pluck(:id, :version)).to eq(versions)
  end
end

RSpec.describe Timekeeping::LocalOwner, "service command key reused for another target" do
  it "the same operation_id reused for a different agent answers idempotency_key_reused and leaves that agent's entries untouched" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    first_agent_entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                                        work_date: "2026-03-02", duration: 60.0, bill_status: "unbilled", agent_id: 77)
    second_agent_entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                                         work_date: "2026-03-02", duration: 60.0, bill_status: "unbilled", agent_id: 78)
    actor = described_class::Actor.service(name: "agent-destroy", company_id: company.id, operations: %w[agents.detach_entries])
    operation_id = SecureRandom.uuid

    first = described_class.call(operation: :detach_entries, company_id: company.id, generation:, actor:,
                                 params: { "agent_id" => 77, "operation_id" => operation_id })
    expect(first.body).to eq("detached" => 1)
    expect(first_agent_entry.reload.agent_id).to be_nil
    baseline = timekeeping_row_counts
    second_before = second_agent_entry.reload.attributes

    # "A reused key with a different target answers `idempotency_key_reused`."
    reused = described_class.call(operation: :detach_entries, company_id: company.id, generation:, actor:,
                                  params: { "agent_id" => 78, "operation_id" => operation_id })

    expect(reused.status).to eq(described_class::STATUS.fetch(:idempotency_key_reused))
    expect(reused.body).to include("reason" => "idempotency_key_reused")
    expect(second_agent_entry.reload.attributes).to eq(second_before)
    expect(timekeeping_row_counts).to eq(baseline)
  end
end

RSpec.describe Timekeeping::LocalOwner, "service command receipts per service and company" do
  it "one operation_id sent by two services and by two companies runs each command and stores a separate receipt for each" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    other_company = create(:company)
    entries = [company, company, other_company].map do |owning|
      member = timekeeping_member(owning, "owner")
      project = create(:project, client: create(:client, company: owning))
      Timekeeping::LocalEntry.create!(company_id: owning.id, user_id: member.id, project_id: project.id,
                                      work_date: "2026-03-02", duration: 60.0, bill_status: "unbilled", agent_id: 77)
    end
    operation_id = SecureRandom.uuid
    grant = %w[agents.detach_entries]
    callers = [
      [company, described_class::Actor.service(name: "agent-destroy", company_id: company.id, operations: grant)],
      [company, described_class::Actor.service(name: "agent-cleanup", company_id: company.id, operations: grant)],
      [other_company, described_class::Actor.service(name: "agent-destroy", company_id: other_company.id, operations: grant)]
    ]
    receipts_before = timekeeping_row_counts["idempotency_records"]

    # "The same operation_id from two services, or from two companies, gives separate receipts"
    answers = callers.map do |owning, actor|
      described_class.call(operation: :detach_entries, company_id: owning.id, generation:, actor:,
                           params: { "agent_id" => 77, "operation_id" => operation_id }).body
    end

    # The second service of the first company finds no entry left with agent 77, so a replay of the
    # first service's answer would show "detached" => 2 instead of its own 0.
    expect(answers).to eq([{ "detached" => 2 }, { "detached" => 0 }, { "detached" => 1 }])
    expect(timekeeping_row_counts["idempotency_records"]).to eq(receipts_before + 3)
    expect(entries.map { |entry| entry.reload.agent_id }).to eq([nil, nil, nil])
  end
end

RSpec.describe Timekeeping::LocalOwner, "service commands on an unpublishable entry" do
  it "mark_billed and detach_entries answer 422 unpublishable_entry with the entry id and field, and write nothing" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                            work_date: "2026-03-02", duration: 60.0, bill_status: "unbilled", agent_id: 77)
    ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql_array([<<~SQL.squish, company.id, entry.id, SecureRandom.uuid]))
      INSERT INTO reservations (company_id, entry_id, invoice_id, operation_id, state, disposition, created_at)
      VALUES (?, ?, 501, ?, 'committed', 'active', NOW())
    SQL
    # A source outside the snapshot contract's list is a stored value the projection refuses.
    entry.update_columns(source: "legacy")
    before = entry.reload.attributes
    baseline = timekeeping_row_counts
    actor = described_class::Actor.service(name: "invoice-boundary", company_id: company.id,
                                           operations: %w[invoices.mark_billed agents.detach_entries])

    { mark_billed: { "invoice_id" => 501 }, detach_entries: { "agent_id" => 77 } }.each do |operation, target|
      outcome = described_class.call(operation:, company_id: company.id, generation:, actor:,
                                     params: target.merge("operation_id" => SecureRandom.uuid))

      # "A flipped or changed entry that fails `EntryOutbox.invalid_fields` refuses the whole command with 422 `unpublishable_entry`."
      expect([operation, outcome.status, outcome.body["reason"]]).to eq([operation, 422, "unpublishable_entry"])
      expect(outcome.body["entries"]).to eq([{ "entry_id" => entry.id, "fields" => ["source"] }])
      expect(timekeeping_row_counts).to eq(baseline)
      expect(entry.reload.attributes).to eq(before)
    end
  end
end

RSpec.describe Timekeeping::LocalOwner, "service commands with an ownership update queued", committed_data: true do
  include LocalOwnerServiceCommandRaceHelpers

  it "mark_billed and detach_entries answer 409 stale_generation without waiting and write nothing" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                            work_date: "2026-03-02", duration: 60.0, bill_status: "unbilled", agent_id: 77)
    ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql_array([<<~SQL.squish, company.id, entry.id, SecureRandom.uuid]))
      INSERT INTO reservations (company_id, entry_id, invoice_id, operation_id, state, disposition, created_at)
      VALUES (?, ?, 501, ?, 'committed', 'active', NOW())
    SQL
    before = entry.reload.attributes
    baseline = timekeeping_row_counts
    actor = described_class::Actor.service(name: "invoice-boundary", company_id: company.id,
                                           operations: %w[invoices.mark_billed agents.detach_entries])
    holding = Queue.new
    release = Queue.new
    holder_pids = []
    updater_pids = []

    holder = updater = nil
    outcomes = {}
    begin
      holder = committed_data_thread(holder_pids) do
        ApplicationRecord.transaction do
          TimekeepingOwnership.lock("FOR SHARE").find(TimekeepingOwnership::SINGLETON_ID)
          holding << true
          release.pop
        end
      end
      await_service_command_worker(holder) { holding.pop(timeout: 0) }
      updater = committed_data_thread(updater_pids) do
        TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID).update_all("generation = generation")
      end
      await_service_command_worker(updater) { updater_pids.first }

      expect(blocked_by?(updater_pids.first, holder_pids.first)).to be(true)
      { mark_billed: { "invoice_id" => 501 }, detach_entries: { "agent_id" => 77 } }.each do |operation, target|
        # statement_timeout, not lock_timeout: a blocking read then fails with a cancelled query
        # instead of the lock_not_available error a NOWAIT read raises.
        ApplicationRecord.transaction do
          ApplicationRecord.connection.execute("SET LOCAL statement_timeout = '2s'")
          outcomes[operation] = described_class.call(operation:, company_id: company.id, generation:, actor:,
                                                     params: target.merge("operation_id" => SecureRandom.uuid))
        end
      end
    ensure
      release << true
      finish_service_command_workers(holder, updater)
    end

    # "A `lock_not_available` error answers 409 `stale_generation` with nothing written."
    expect(outcomes.transform_values { |outcome| [outcome.status, outcome.body] })
      .to eq(mark_billed: [409, { "reason" => "stale_generation" }], detach_entries: [409, { "reason" => "stale_generation" }])
    expect(timekeeping_row_counts).to eq(baseline)
    expect(entry.reload.attributes).to eq(before)
  end
end

RSpec.describe Timekeeping::LocalOwner, "service command key reused for another target at the same time", committed_data: true do
  include LocalOwnerServiceCommandRaceHelpers

  it "a second session sending one operation_id for another agent waits for the first and answers idempotency_key_reused" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    first_entry, second_entry = [77, 78].map do |agent_id|
      Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                      work_date: "2026-03-02", duration: 60.0, bill_status: "unbilled", agent_id:)
    end
    actor = described_class::Actor.service(name: "agent-destroy", company_id: company.id,
                                           operations: %w[agents.detach_entries])
    operation_id = SecureRandom.uuid
    paused = Queue.new
    release = Queue.new
    first_pids = []
    second_pids = []
    pause_after_rows_locked = lambda do |step|
      next unless step == :rows_locked

      paused << true
      release.pop
    end

    first = second = nil
    begin
      first = committed_data_thread(first_pids) do
        described_class.call(operation: :detach_entries, company_id: company.id, generation:, actor:,
                             params: { "agent_id" => 77, "operation_id" => operation_id },
                             checkpoint: pause_after_rows_locked)
      end
      await_service_command_worker(first) { paused.pop(timeout: 0) }
      second = committed_data_thread(second_pids) do
        described_class.call(operation: :detach_entries, company_id: company.id, generation:, actor:,
                             params: { "agent_id" => 78, "operation_id" => operation_id })
      end
      await_service_command_worker(second) { second_pids.first }

      # Without the operation lock that leaves out the target, the second session would not wait here,
      # would find no receipt yet, and would detach agent 78 as a second command.
      expect(blocked_by?(second_pids.first, first_pids.first)).to be(true)
    ensure
      release << true
      finish_service_command_workers(first, second)
    end

    expect(first.value.body).to eq("detached" => 1)
    # "A reused key with a different target answers `idempotency_key_reused`."
    expect(second.value.body).to include("reason" => "idempotency_key_reused")
    expect([first_entry.reload.agent_id, second_entry.reload.agent_id]).to eq([nil, 78])
  end
end

RSpec.describe Timekeeping::LocalOwner, "stored service command receipts" do
  it "stores each command's receipt as a service receipt with the target-qualified operation and its SHA256 fingerprint" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    actor = described_class::Actor.service(name: "invoice-boundary", company_id: company.id,
                                           operations: %w[invoices.mark_billed agents.detach_entries])
    commands = { mark_billed: ["invoice_id", 501, "mark_billed 501"], detach_entries: ["agent_id", 77, "detach_entries 77"] }

    commands.each do |operation, (target_param, target_id, operation_name)|
      operation_id = SecureRandom.uuid
      described_class.call(operation:, company_id: company.id, generation:, actor:,
                           params: { target_param => target_id, "operation_id" => operation_id })

      # "Write service receipts with `actor_type "service"`, a nil `actor_id` and `actor_name` = service name.
      # The receipt operation includes the target, and the fingerprint is SHA256 of `"<route> <target>"`"
      receipt = described_class::Receipt.find_by!(company_id: company.id, key: operation_id)
      expect(receipt.attributes.slice("actor_type", "actor_id", "actor_name", "operation", "fingerprint")).to eq(
        "actor_type" => "service", "actor_id" => nil, "actor_name" => "invoice-boundary",
        "operation" => operation_name, "fingerprint" => Digest::SHA256.hexdigest(operation_name)
      )
    end
  end
end

RSpec.describe Timekeeping::LocalOwner::ServiceCommands, "detach marker scoped by company" do
  # Receipts of every company share the idempotency_records table, so a lookup
  # without its company filter would let one company's detach refuse another's writes.
  it "detach_marker finds a detach receipt only in the company the detach ran in" do
    generation = prepare_local_ownership!.generation.to_s
    company_a = create(:company)
    company_b = create(:company)
    actor = Timekeeping::LocalOwner::Actor.service(name: "agent-destroy", company_id: company_a.id,
                                                   operations: ["agents.detach_entries"])
    outcome = Timekeeping::LocalOwner.call(
      operation: :detach_entries, company_id: company_a.id, generation:, actor:,
      params: { "agent_id" => 77, "operation_id" => SecureRandom.uuid }
    )
    expect(outcome.status).to eq(200)
    receipt_id = Timekeeping::LocalOwner::Receipt
      .where(company_id: company_a.id, actor_type: "service", operation: "detach_entries 77").pick(:id)
    expect(receipt_id).not_to be_nil

    expect(described_class.detach_marker(company_a.id, 77)).to eq(receipt_id)
    expect(described_class.detach_marker(company_b.id, 77)).to eq(0)
  end
end

RSpec.describe Timekeeping::LocalOwner::ServiceCommands, "agent_detached? scoped by company" do
  it "agent_detached? reports a detach only for the company the detach ran in" do
    generation = prepare_local_ownership!.generation.to_s
    company_a = create(:company)
    company_b = create(:company)
    actor = Timekeeping::LocalOwner::Actor.service(name: "agent-destroy", company_id: company_a.id,
                                                   operations: ["agents.detach_entries"])
    outcome = Timekeeping::LocalOwner.call(
      operation: :detach_entries, company_id: company_a.id, generation:, actor:,
      params: { "agent_id" => 88, "operation_id" => SecureRandom.uuid }
    )
    expect(outcome.status).to eq(200)

    expect(described_class.agent_detached?(company_a.id, 88, after: 0)).to be(true)
    expect(described_class.agent_detached?(company_b.id, 88, after: 0)).to be(false)
  end
end

RSpec.describe Timekeeping::LocalOwner::ServiceCommands, "agent_detached? after a marker" do
  it "agent_detached? ignores a detach at or below the marker and reports one above it" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    actor = Timekeeping::LocalOwner::Actor.service(name: "agent-destroy", company_id: company.id,
                                                   operations: ["agents.detach_entries"])
    detach = lambda do
      Timekeeping::LocalOwner.call(operation: :detach_entries, company_id: company.id, generation:, actor:,
                                   params: { "agent_id" => 77, "operation_id" => SecureRandom.uuid })
    end
    expect(described_class.detach_marker(company.id, 77)).to eq(0)
    expect(detach.call.status).to eq(200)
    marker = described_class.detach_marker(company.id, 77)

    expect(described_class.agent_detached?(company.id, 77, after: marker)).to be(false)
    expect(described_class.agent_detached?(company.id, 77, after: 0)).to be(true)

    expect(detach.call.status).to eq(200)
    expect(described_class.agent_detached?(company.id, 77, after: marker)).to be(true)
  end
end
