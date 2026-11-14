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

# Setup the service-command examples share, so a change to how an entry or a reservation is
# seeded is made once. Every detail that makes an example its own case (company, member role,
# agent, invoice, reservation state, entry attributes) is an argument, never a default here.
module LocalOwnerServiceCommandSetup
  # An unbilled entry for the given member and project. The attributes carry what differs
  # between examples: work_date, duration, note and agent_id.
  def service_command_entry(company, user:, project:, **attributes)
    Timekeeping::LocalEntry.create!(company_id: company.id, user_id: user.id, project_id: project.id,
                                    bill_status: "unbilled", **attributes)
  end

  # An entry under a new member with the given role and a new project, for examples that seed
  # entries in more than one company.
  def service_command_company_entry(company, role:, **attributes)
    member = timekeeping_member(company, role)
    project = create(:project, client: create(:client, company:))
    service_command_entry(company, user: member, project:, **attributes)
  end

  # Writes the reservation row directly, because the examples need committed and provisional
  # rows without running the reservation commands that would produce them.
  def reserve_service_command_entry(entry, invoice_id, state:)
    ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql_array([<<~SQL.squish, entry.company_id, entry.id, invoice_id, SecureRandom.uuid, state]))
      INSERT INTO reservations (company_id, entry_id, invoice_id, operation_id, state, disposition, created_at)
      VALUES (?, ?, ?, ?, ?, 'active', NOW())
    SQL
  end

  def count_rows(table, entry_id)
    ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(["SELECT COUNT(*) FROM #{table} WHERE entry_id = ?", entry_id])
    ).to_i
  end
end

RSpec.describe Timekeeping::LocalOwner, "service command access refusals" do
  include LocalOwnerServiceCommandSetup

  it "refuses nil, user, ungranted and foreign-company callers of mark_billed and detach_entries with 401, 403, 403 and 404 before any lock and with nothing changed" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    other_company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice_id = create(:invoice, company:, client: project.client).id
    agent_id = 77
    billable = service_command_entry(company, user: owner, project:, work_date: "2026-03-02", duration: 60.0)
    reserve_service_command_entry(billable, invoice_id, state: "committed")
    agent_entry = service_command_entry(company, user: owner, project:, work_date: "2026-03-02", duration: 60.0, agent_id:)
    # One entry each command would change: reserved on the invoice and carrying the agent.
    billable_agent_entry = service_command_entry(company, user: owner, project:, work_date: Date.current, duration: 30.0,
                                                 note: "n", agent_id:)
    reserve_service_command_entry(billable_agent_entry, invoice_id, state: "committed")
    entries = [billable, agent_entry, billable_agent_entry]
    before = entries.map { |entry| entry.reload.attributes }
    expect(before.map { |attributes| attributes.values_at("bill_status", "agent_id") })
      .to eq([["unbilled", nil], ["unbilled", agent_id], ["unbilled", agent_id]])
    baseline = timekeeping_row_counts
    actor = described_class::Actor
    targets = { mark_billed: { "invoice_id" => invoice_id }, detach_entries: { "agent_id" => agent_id } }
    # Each command is refused when the caller holds only the other command's operation.
    other_operation = { mark_billed: "agents.detach_entries", detach_entries: "invoices.mark_billed" }
    granted_operation = { mark_billed: "invoices.mark_billed", detach_entries: "agents.detach_entries" }

    targets.each do |operation, target|
      # "A nil actor answers unauthorized, a user actor or a service without the qualified operation (invoices.mark_billed, agents.detach_entries) answers forbidden, and a service bound to another company answers not_found, all with nothing changed"
      # The other company's service is refused both when it holds only this command's operation
      # and when it holds both operations.
      callers = [
        [nil, 401, "unauthorized"],
        [actor.user(user_id: owner.id, role: "owner"), 403, "forbidden"],
        [actor.service(name: "invoice-boundary", company_id: company.id, operations: [other_operation.fetch(operation)]),
         403, "forbidden"],
        [actor.service(name: "invoice-boundary", company_id: other_company.id, operations: [granted_operation.fetch(operation)]),
         404, "not_found"],
        [actor.service(name: "invoice-boundary", company_id: other_company.id, operations: granted_operation.values),
         404, "not_found"]
      ]

      callers.each do |caller, status, reason|
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
        expect(entries.map { |entry| entry.reload.attributes }).to eq(before)
      end
    end
  end
end

RSpec.describe Timekeeping::LocalOwner, "service command target checks" do
  include LocalOwnerServiceCommandSetup

  it "refuses detach_entries with a missing or non-integer agent_id and never touches the company's entries that have no agent" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    unassigned = service_command_company_entry(company, role: "employee", work_date: "2026-03-02", duration: 60.0)
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

RSpec.describe Timekeeping::LocalOwner, "service command key reuse" do
  include LocalOwnerServiceCommandSetup

  it "reusing a detach_entries operation_id for a different agent answers idempotency_key_reused and writes nothing" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    user = timekeeping_member(company, "employee")
    project = create(:project, client: create(:client, company:))
    detached_entry = service_command_entry(company, user:, project:, work_date: "2026-03-02", duration: 60.0, agent_id: 77)
    other_agent_entry = service_command_entry(company, user:, project:, work_date: "2026-03-02", duration: 60.0, agent_id: 78)
    actor = described_class::Actor.service(name: "agent-destroy", company_id: company.id,
                                           operations: ["agents.detach_entries"])
    operation_id = SecureRandom.uuid
    first = described_class.call(operation: :detach_entries, company_id: company.id, generation:, actor:,
                                 params: { "agent_id" => 77, "operation_id" => operation_id })
    expect(first.body).to eq("detached" => 1)
    expect(detached_entry.reload.agent_id).to be_nil
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

RSpec.describe Timekeeping::LocalOwner, "mark_billed tenant boundary" do
  include LocalOwnerServiceCommandSetup

  it "mark_billed bills only the caller company's entries when another company holds a committed reservation for the same invoice number" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    other_company = create(:company)
    invoice_number = 501
    own_entry, foreign_entry = [company, other_company].map do |owning_company|
      entry = service_command_company_entry(owning_company, role: "employee", work_date: "2026-03-02", duration: 60.0)
      reserve_service_command_entry(entry, invoice_number, state: "committed")
      entry
    end
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
  include LocalOwnerServiceCommandSetup

  it "a service bound to another company gets not_found on mark_billed and detach_entries, even for an operation_id with a stored receipt, and nothing changes" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    other_company = create(:company)
    member = timekeeping_member(company, "employee")
    project = create(:project, client: create(:client, company:))
    agent_entry = service_command_entry(company, user: member, project:, work_date: "2026-03-02", duration: 60.0, agent_id: 77)
    billable = service_command_entry(company, user: member, project:, work_date: "2026-03-02", duration: 60.0)
    reserve_service_command_entry(billable, 501, state: "committed")
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

RSpec.describe Timekeeping::LocalOwner, "mark_billed on committed reservations" do
  include LocalOwnerServiceCommandSetup

  it "mark_billed bills the two committed entries, skips a provisional entry and another invoice's entry, and writes version, one audit, one outbox row each and one receipt" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    other_invoice = create(:invoice, company:, client: project.client)
    x, y, provisional, elsewhere = Array.new(4) do
      service_command_entry(company, user: owner, project:, work_date: Date.current, duration: 30.0, note: "n")
    end
    reserve_service_command_entry(x, invoice.id, state: "committed")
    reserve_service_command_entry(y, invoice.id, state: "committed")
    reserve_service_command_entry(provisional, invoice.id, state: "provisional")
    reserve_service_command_entry(elsewhere, other_invoice.id, state: "committed")
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
  include LocalOwnerServiceCommandSetup

  it "detach_entries clears agent 77 on the caller company's entries and leaves the same agent id on a second company's entry untouched" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    other_company = create(:company)
    first_own, second_own, other_agent, foreign = [[company, 77], [company, 77], [company, 78], [other_company, 77]].map do |owning, agent_id|
      service_command_company_entry(owning, role: "owner", work_date: Date.current, duration: 30.0, note: "n", agent_id:)
    end
    own = [first_own, second_own]
    foreign_before = foreign.reload.attributes
    other_agent_before = other_agent.reload.attributes
    own_versions = own.map { |entry| entry.reload.version }
    outbox_before = timekeeping_row_counts["entry_outbox_items"]
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
    # Only the caller company's two changed entries get an outbox snapshot.
    expect(timekeeping_row_counts["entry_outbox_items"]).to eq(outbox_before + 2)
  end
end

RSpec.describe Timekeeping::LocalOwner, "service command retries" do
  include LocalOwnerServiceCommandSetup

  it "a retry at a stale generation after a stored receipt answers 409 stale_generation and writes nothing, while a retry at the current generation replays the first answer with no new rows" do
    ownership = prepare_local_ownership!
    generation = ownership.generation.to_s
    stale = (Integer(generation, 10) - 1).to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    billable = service_command_entry(company, user: owner, project:, work_date: Date.current, duration: 30.0, note: "n")
    reserve_service_command_entry(billable, invoice.id, state: "committed")
    agent_entry = service_command_entry(company, user: owner, project:, work_date: Date.current, duration: 30.0, note: "n", agent_id: 77)
    actor = described_class::Actor.service(name: "invoice-boundary", company_id: company.id,
                                           operations: ["invoices.mark_billed", "agents.detach_entries"])
    commands = { mark_billed: { "invoice_id" => invoice.id }, detach_entries: { "agent_id" => 77 } }
    stored_params = commands.to_h { |operation, target| [operation, target.merge("operation_id" => SecureRandom.uuid)] }

    stored_params.each do |operation, params|
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

    # The ownership generation moves on after both receipts are stored, so the generation each
    # stored answer was given under is now stale too.
    ownership.update!(generation: ownership.generation + 1)
    baseline = timekeeping_row_counts
    versions = Timekeeping::LocalEntry.where(company_id: company.id).order(:id).pluck(:id, :version)

    stored_params.each do |operation, params|
      retry_outcome = described_class.call(operation:, company_id: company.id, generation:, actor:, params:)

      expect([operation, retry_outcome.status, retry_outcome.body]).to eq([operation, 409, { "reason" => "stale_generation" }])
      expect(timekeeping_row_counts).to eq(baseline)
      expect(Timekeeping::LocalEntry.where(company_id: company.id).order(:id).pluck(:id, :version)).to eq(versions)
    end
  end
end

RSpec.describe Timekeeping::LocalOwner, "service command rollback" do
  include LocalOwnerServiceCommandSetup

  it "a failure injected at entry_written or outbox_written leaves no entry change, audit, outbox row or receipt, and a later retry with the same key still runs" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    entry = service_command_entry(company, user: owner, project:, work_date: Date.current, duration: 30.0, note: "n", agent_id: 77)
    reserve_service_command_entry(entry, invoice.id, state: "committed")
    actor = described_class::Actor.service(name: "invoice-boundary", company_id: company.id,
                                           operations: ["invoices.mark_billed", "agents.detach_entries"])
    injected = Class.new(StandardError)
    commands = {
      mark_billed: [{ "invoice_id" => invoice.id }, { "billed" => 1 }],
      detach_entries: [{ "agent_id" => 77 }, { "detached" => 1 }]
    }

    # "A failure injected after the entry write leaves no outbox row or receipt."
    commands.each do |operation, (target, answer)|
      # Every failing call and the retry share one key, so the retry shows that no failure left a
      # receipt behind for that key.
      params = target.merge("operation_id" => SecureRandom.uuid)
      %i[entry_written outbox_written].each do |step|
        expect(described_class::STEPS).to include(step)
        baseline = timekeeping_row_counts
        entry_before = entry.reload.attributes
        seen_steps = []

        expect {
          described_class.call(operation:, company_id: company.id, generation:, actor:,
                               params:,
                               checkpoint: lambda { |seen|
                                 seen_steps << seen
                                 raise injected if seen == step
                               })
        }.to raise_error(injected)

        expect(seen_steps).to include(step)
        expect(timekeeping_row_counts).to eq(baseline)
        expect(entry.reload.attributes).to eq(entry_before)
      end

      # Nothing was stored, so the same key runs as a first attempt.
      outcome = described_class.call(operation:, company_id: company.id, generation:, actor:, params:)
      expect([operation, outcome.status, outcome.body]).to eq([operation, 200, answer])
    end
    expect(entry.reload.attributes.values_at("bill_status", "agent_id")).to eq(["billed", nil])
  end
end

RSpec.describe Timekeeping::LocalOwner, "service command receipts per service and company" do
  include LocalOwnerServiceCommandSetup

  it "one operation_id sent by two services and by two companies runs each command and stores a separate receipt for each, and never replays a stored answer to a refused caller" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    other_company = create(:company)
    actor = described_class::Actor
    receipt_owners = lambda do |operation_id|
      described_class::Receipt.where(key: operation_id, actor_type: "service").pluck(:company_id, :actor_name)
    end

    # mark_billed: both companies hold a committed reservation for the same invoice number.
    invoice_id = 501
    own_billable, foreign_billable = [company, other_company].map do |owning|
      entry = service_command_company_entry(owning, role: "employee", work_date: "2026-03-02", duration: 60.0)
      reserve_service_command_entry(entry, invoice_id, state: "committed")
      entry
    end
    bill_params = { "invoice_id" => invoice_id, "operation_id" => SecureRandom.uuid }
    bill = lambda do |caller, company_id|
      described_class.call(operation: :mark_billed, company_id:, generation:, actor: caller, params: bill_params)
    end
    invoice_service = actor.service(name: "invoice-boundary", company_id: company.id, operations: ["invoices.mark_billed"])
    foreign_invoice_service = actor.service(name: "invoice-boundary", company_id: other_company.id, operations: ["invoices.mark_billed"])

    first_bill = bill.call(invoice_service, company.id)
    expect([first_bill.status, first_bill.body]).to eq([200, { "billed" => 1 }])
    baseline = timekeeping_row_counts
    foreign_billable_before = foreign_billable.reload.attributes

    # A caller that access refuses learns nothing of the stored answer, even with the same service name and key.
    [
      [actor.service(name: "invoice-boundary", company_id: company.id, operations: ["agents.detach_entries"]), 403, "forbidden"],
      [foreign_invoice_service, 404, "not_found"]
    ].each do |caller, status, reason|
      refused = bill.call(caller, company.id)
      expect([refused.status, refused.body]).to eq([status, { "reason" => reason }])
      expect(timekeeping_row_counts).to eq(baseline)
      expect(foreign_billable.reload.attributes).to eq(foreign_billable_before)
    end

    # "The same operation_id from two services, or from two companies, gives separate receipts"
    foreign_bill = bill.call(foreign_invoice_service, other_company.id)
    expect([foreign_bill.status, foreign_bill.body]).to eq([200, { "billed" => 1 }])
    expect([own_billable, foreign_billable].map { |entry| entry.reload.bill_status }).to eq(%w[billed billed])
    expect(receipt_owners.call(bill_params["operation_id"]))
      .to contain_exactly([company.id, "invoice-boundary"], [other_company.id, "invoice-boundary"])

    # detach_entries: two entries with agent 77 and one with agent 78 in the first company, one with
    # agent 77 in the other.
    entries = [[company, 77], [company, 77], [company, 78], [other_company, 77]].map do |owning, agent_id|
      service_command_company_entry(owning, role: "owner", work_date: "2026-03-02", duration: 60.0, agent_id:)
    end
    foreign_entry = entries.last
    detach_operation_id = SecureRandom.uuid
    grant = %w[agents.detach_entries]
    detach = lambda do |owning, caller, agent_id|
      described_class.call(operation: :detach_entries, company_id: owning.id, generation:, actor: caller,
                           params: { "agent_id" => agent_id, "operation_id" => detach_operation_id })
    end
    foreign_destroy_service = actor.service(name: "agent-destroy", company_id: other_company.id, operations: grant)
    receipts_before = timekeeping_row_counts["idempotency_records"]

    first_detach = detach.call(company, actor.service(name: "agent-destroy", company_id: company.id, operations: grant), 77)
    expect(first_detach.body).to eq("detached" => 2)
    expect(foreign_entry.reload.agent_id).to eq(77)
    baseline = timekeeping_row_counts
    entries_before = entries.map { |entry| entry.reload.attributes }

    [
      [actor.service(name: "agent-destroy", company_id: company.id, operations: ["invoices.mark_billed"]), 403, "forbidden"],
      [foreign_destroy_service, 404, "not_found"]
    ].each do |caller, status, reason|
      refused = detach.call(company, caller, 77)
      expect([refused.status, refused.body]).to eq([status, { "reason" => reason }])
      expect(timekeeping_row_counts).to eq(baseline)
      expect(entries.map { |entry| entry.reload.attributes }).to eq(entries_before)
    end

    answers = [
      detach.call(company, actor.service(name: "agent-cleanup", company_id: company.id, operations: grant), 77),
      # Another service may send the same key for another agent: it gets its own receipt, not idempotency_key_reused.
      detach.call(company, actor.service(name: "agent-sweep", company_id: company.id, operations: grant), 78),
      detach.call(other_company, foreign_destroy_service, 77)
    ].map(&:body)

    # The second service of the first company finds no entry left with agent 77, so a replay of the
    # first service's answer would show "detached" => 2 instead of its own 0.
    expect(answers).to eq([{ "detached" => 0 }, { "detached" => 1 }, { "detached" => 1 }])
    expect(timekeeping_row_counts["idempotency_records"]).to eq(receipts_before + 4)
    expect(receipt_owners.call(detach_operation_id)).to contain_exactly(
      [company.id, "agent-destroy"], [company.id, "agent-cleanup"], [company.id, "agent-sweep"], [other_company.id, "agent-destroy"]
    )
    expect(entries.map { |entry| entry.reload.agent_id }).to eq([nil, nil, nil, nil])
  end
end

RSpec.describe Timekeeping::LocalOwner, "service commands on an unpublishable entry" do
  include LocalOwnerServiceCommandSetup

  it "mark_billed and detach_entries answer 422 unpublishable_entry with the entry id and field, and write nothing" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    entry = service_command_company_entry(company, role: "owner", work_date: "2026-03-02", duration: 60.0, agent_id: 77)
    reserve_service_command_entry(entry, 501, state: "committed")
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
  include LocalOwnerServiceCommandSetup

  it "mark_billed and detach_entries answer 409 stale_generation without waiting and write nothing" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    entry = service_command_company_entry(company, role: "owner", work_date: "2026-03-02", duration: 60.0, agent_id: 77)
    reserve_service_command_entry(entry, 501, state: "committed")
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
  include LocalOwnerServiceCommandSetup

  it "a second session sending one operation_id for another agent waits for the first and answers idempotency_key_reused" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    first_entry, second_entry = [77, 78].map do |agent_id|
      service_command_entry(company, user: owner, project:, work_date: "2026-03-02", duration: 60.0, agent_id:)
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
