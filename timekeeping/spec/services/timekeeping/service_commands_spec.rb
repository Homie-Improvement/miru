# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

RSpec.describe Timekeeping::ServiceCommands do
  include_context "timekeeping entry writes"

  let(:company) { timekeeping_arrange.company }
  let(:other_company) { timekeeping_arrange.company }

  def service_command(route, target_id:, operation_id: SecureRandom.uuid, company_id: company,
                      generation: timekeeping_arrange.current_generation)
    request = described_class::Request.new(route:, company_id:, actor_name: "invoice-boundary", target_id:,
                                           operation_id:, generation:)
    outcome = described_class.new.call(request)
    [outcome.status, JSON.parse(outcome.body)]
  end

  def plain_entry(company_id, **attributes)
    timekeeping_arrange.entry(company: company_id, user: timekeeping_arrange.user(company: company_id, role: "employee"),
                              project: timekeeping_arrange.project(company: company_id), **attributes)
  end

  def command_row_counts
    { audit_events: AuditEvent.count, outbox_snapshots: OutboxSnapshot.count,
      receipts: ServiceIdempotencyReceipt.count, versions: Entry.sum(:version) }
  end

  it "bills only the kept, unbilled entries with a committed reservation for that invoice in that company" do
    billable = timekeeping_arrange.reserved_entry(company:, invoice_id: 501)
    provisional = timekeeping_arrange.reserved_entry(company:, invoice_id: 501, state: "provisional")
    other_invoice = timekeeping_arrange.reserved_entry(company:, invoice_id: 502)
    discarded = timekeeping_arrange.reserved_entry(company:, invoice_id: 501, discarded_at: Time.current)
    already = timekeeping_arrange.reserved_entry(company:, invoice_id: 501, bill_status: "billed")
    foreign = timekeeping_arrange.reserved_entry(company: other_company, invoice_id: 501)
    versions = Entry.where(id: [already, foreign]).order(:id).pluck(:version)

    expect(service_command(:mark_billed, target_id: 501)).to eq([200, { "billed" => 1 }])
    expect(Entry.where(id: [billable, provisional, other_invoice, discarded, foreign]).order(:id).pluck(:bill_status))
      .to eq(%w[billed unbilled unbilled unbilled unbilled])
    expect(Entry.where(id: [already, foreign]).order(:id).pluck(:version)).to eq(versions)
    audit = AuditEvent.find_by!(entry_id: billable)
    expect([audit.action, audit.actor_type, audit.actor_name, audit.before, audit.after])
      .to eq(["mark_billed", "service", "invoice-boundary", { "bill_status" => "unbilled" }, { "bill_status" => "billed" }])
  end

  it "answers a replayed mark-billed from its receipt and bills nothing again" do
    billable = timekeeping_arrange.reserved_entry(company:, invoice_id: 501)
    operation_id = SecureRandom.uuid
    first = service_command(:mark_billed, target_id: 501, operation_id:)
    Entry.where(id: billable).update_all(bill_status: "unbilled")
    after_first = command_row_counts

    expect(service_command(:mark_billed, target_id: 501, operation_id:)).to eq(first)
    expect(command_row_counts).to eq(after_first)
    expect(Entry.find(billable).bill_status).to eq("unbilled")
  end

  it "detaches only the path company's entries for the agent, with one audit and one outbox row each" do
    own = [plain_entry(company, agent_id: 77), plain_entry(company, agent_id: 77, discarded_at: Time.current)]
    other_agent = plain_entry(company, agent_id: 78)
    foreign = plain_entry(other_company, agent_id: 77)

    expect(service_command(:detach_entries, target_id: 77)).to eq([200, { "detached" => 2 }])
    expect(Entry.where(id: own + [other_agent, foreign]).order(:id).pluck(:agent_id)).to eq([nil, nil, 78, 77])
    expect(own.map { |id| [AuditEvent.where(entry_id: id).count, OutboxSnapshot.where(id:).count] }).to eq([[1, 1], [1, 1]])
    expect(AuditEvent.where(entry_id: [other_agent, foreign]).count).to eq(0)
    snapshot = OutboxSnapshot.find_by!(id: own.first)
    expect([snapshot.agent_id, snapshot.version, snapshot.company_id]).to eq([nil, Entry.find(own.first).version, company])
    audit = AuditEvent.find_by!(entry_id: own.first)
    expect([audit.action, audit.before, audit.after]).to eq(["detach_entries", { "agent_id" => 77 }, { "agent_id" => nil }])
  end

  it "leaves agent_id, bill_status and every row count unchanged when the outbox insert fails" do
    billable = timekeeping_arrange.reserved_entry(company:, invoice_id: 501)
    attached = plain_entry(company, agent_id: 77)
    before = command_row_counts
    allow(OutboxSnapshot).to receive(:insert_all!).and_raise(ActiveRecord::StatementInvalid, "outbox down")

    expect { service_command(:mark_billed, target_id: 501) }.to raise_error(ActiveRecord::StatementInvalid, "outbox down")
    expect { service_command(:detach_entries, target_id: 77) }.to raise_error(ActiveRecord::StatementInvalid, "outbox down")
    expect([Entry.find(billable).bill_status, Entry.find(attached).agent_id]).to eq(["unbilled", 77])
    expect(command_row_counts).to eq(before)
  end

  it "refuses a stale generation and writes nothing" do
    billable = timekeeping_arrange.reserved_entry(company:, invoice_id: 501)
    attached = plain_entry(company, agent_id: 77)
    before = command_row_counts
    stale = timekeeping_arrange.current_generation + 1

    expect(service_command(:mark_billed, target_id: 501, generation: stale)).to eq([409, { "reason" => "stale_generation" }])
    expect(service_command(:detach_entries, target_id: 77, generation: stale)).to eq([409, { "reason" => "stale_generation" }])
    expect([Entry.find(billable).bill_status, Entry.find(attached).agent_id]).to eq(["unbilled", 77])
    expect(command_row_counts).to eq(before)
  end
end

# Generated by Descant: acceptance tests below.
require "rails_helper"

RSpec.describe Timekeeping::ServiceCommands do
  include_context "timekeeping entry writes"

  # "Add replay cases that complete an operation, advance the company's generation, and resend the original
  # request with its original generation. Cover prepare, commit, abort, mark-billed and detach-entries, and
  # assert the stored answer and unchanged business state."
  it "replays a finished mark-billed from its receipt after the generation advances" do
    company = timekeeping_arrange.company
    send_mark_billed = lambda do |operation_id, generation|
      request = described_class::Request.new(route: :mark_billed, company_id: company, actor_name: "invoice-boundary",
                                             target_id: 501, operation_id:, generation:)
      outcome = described_class.new.call(request)
      [outcome.status, JSON.parse(outcome.body)]
    end
    row_counts = -> { [AuditEvent.count, OutboxSnapshot.count, ServiceIdempotencyReceipt.count, Entry.sum(:version)] }
    billable = timekeeping_arrange.reserved_entry(company:, invoice_id: 501)
    operation_id = SecureRandom.uuid
    original = timekeeping_arrange.current_generation

    first = send_mark_billed.call(operation_id, original)
    expect(first).to eq([200, { "billed" => 1 }])
    timekeeping_arrange.set_generation(original + 1)
    # A re-run would bill this entry again, so the reset makes a second effect visible.
    Entry.where(id: billable).update_all(bill_status: "unbilled")
    expect(Entry.find(billable).bill_status).to eq("unbilled")
    baseline = row_counts.call

    expect(send_mark_billed.call(operation_id, original)).to eq(first)
    expect(row_counts.call).to eq(baseline)
    expect(Entry.find(billable).bill_status).to eq("unbilled")
    # Control: the original generation really is stale for work that was never finished.
    expect(send_mark_billed.call(SecureRandom.uuid, original)).to eq([409, { "reason" => "stale_generation" }])
    expect(row_counts.call).to eq(baseline)
  end
end

require "rails_helper"

RSpec.describe Timekeeping::ServiceCommands do
  include_context "timekeeping entry writes"

  # "Add replay cases that complete an operation, advance the company's generation, and resend the original
  # request with its original generation. Cover prepare, commit, abort, mark-billed and detach-entries, and
  # assert the stored answer and unchanged business state."
  it "replays a finished detach-entries from its receipt after the generation advances" do
    company = timekeeping_arrange.company
    send_detach = lambda do |operation_id, generation|
      request = described_class::Request.new(route: :detach_entries, company_id: company, actor_name: "invoice-boundary",
                                             target_id: 77, operation_id:, generation:)
      outcome = described_class.new.call(request)
      [outcome.status, JSON.parse(outcome.body)]
    end
    row_counts = -> { [AuditEvent.count, OutboxSnapshot.count, ServiceIdempotencyReceipt.count, Entry.sum(:version)] }
    attached = timekeeping_arrange.entry(company:, user: timekeeping_arrange.user(company:, role: "employee"),
                                         project: timekeeping_arrange.project(company:), agent_id: 77)
    operation_id = SecureRandom.uuid
    original = timekeeping_arrange.current_generation

    first = send_detach.call(operation_id, original)
    expect(first).to eq([200, { "detached" => 1 }])
    timekeeping_arrange.set_generation(original + 1)
    # A re-run would detach this entry again, so the reset makes a second effect visible.
    Entry.where(id: attached).update_all(agent_id: 77)
    expect(Entry.find(attached).agent_id).to eq(77)
    baseline = row_counts.call

    expect(send_detach.call(operation_id, original)).to eq(first)
    expect(row_counts.call).to eq(baseline)
    expect(Entry.find(attached).agent_id).to eq(77)
    # Control: the original generation really is stale for work that was never finished.
    expect(send_detach.call(SecureRandom.uuid, original)).to eq([409, { "reason" => "stale_generation" }])
    expect(row_counts.call).to eq(baseline)
  end
end

require "rails_helper"
require "webmock/rspec"

RSpec.describe Timekeeping::ServiceCommands do
  include_context "timekeeping entry writes"

  it "replays a finished mark-billed with its original generation after the generation advances and bills nothing again" do
    company = timekeeping_arrange.company
    send_command = lambda do |operation_id, generation|
      request = described_class::Request.new(route: :mark_billed, company_id: company, actor_name: "invoice-boundary",
                                             target_id: 501, operation_id:, generation:)
      outcome = described_class.new.call(request)
      [outcome.status, JSON.parse(outcome.body)]
    end
    row_counts = lambda do
      { audit_events: AuditEvent.count, outbox_snapshots: OutboxSnapshot.count,
        receipts: ServiceIdempotencyReceipt.count, versions: Entry.sum(:version) }
    end
    billable = timekeeping_arrange.reserved_entry(company:, invoice_id: 501)
    operation_id = SecureRandom.uuid
    original = timekeeping_arrange.current_generation
    first = send_command.call(operation_id, original)
    expect(first).to eq([200, { "billed" => 1 }])
    timekeeping_arrange.set_generation(original + 1)
    Entry.where(id: billable).update_all(bill_status: "unbilled")
    expect(Entry.find(billable).bill_status).to eq("unbilled")
    baseline = row_counts.call

    # "Add replay cases that complete an operation, advance the company's generation, and resend the original request with its original generation."
    expect(send_command.call(operation_id, original)).to eq(first)
    expect(row_counts.call).to eq(baseline)
    expect(Entry.find(billable).bill_status).to eq("unbilled")
    # The same old generation under a new operation id is refused, so the replay really was sent stale.
    expect(send_command.call(SecureRandom.uuid, original)).to eq([409, { "reason" => "stale_generation" }])
  end
end

require "rails_helper"
require "webmock/rspec"

RSpec.describe Timekeeping::ServiceCommands do
  include_context "timekeeping entry writes"

  it "replays a finished detach-entries with its original generation after the generation advances and detaches nothing again" do
    company = timekeeping_arrange.company
    send_command = lambda do |operation_id, generation|
      request = described_class::Request.new(route: :detach_entries, company_id: company, actor_name: "invoice-boundary",
                                             target_id: 77, operation_id:, generation:)
      outcome = described_class.new.call(request)
      [outcome.status, JSON.parse(outcome.body)]
    end
    row_counts = lambda do
      { audit_events: AuditEvent.count, outbox_snapshots: OutboxSnapshot.count,
        receipts: ServiceIdempotencyReceipt.count, versions: Entry.sum(:version) }
    end
    attached = timekeeping_arrange.entry(company:, user: timekeeping_arrange.user(company:, role: "employee"),
                                         project: timekeeping_arrange.project(company:), agent_id: 77)
    operation_id = SecureRandom.uuid
    original = timekeeping_arrange.current_generation
    first = send_command.call(operation_id, original)
    expect(first).to eq([200, { "detached" => 1 }])
    timekeeping_arrange.set_generation(original + 1)
    Entry.where(id: attached).update_all(agent_id: 77)
    expect(Entry.find(attached).agent_id).to eq(77)
    baseline = row_counts.call

    # "Add replay cases that complete an operation, advance the company's generation, and resend the original request with its original generation."
    expect(send_command.call(operation_id, original)).to eq(first)
    expect(row_counts.call).to eq(baseline)
    expect(Entry.find(attached).agent_id).to eq(77)
    # The same old generation under a new operation id is refused, so the replay really was sent stale.
    expect(send_command.call(SecureRandom.uuid, original)).to eq([409, { "reason" => "stale_generation" }])
  end
end

RSpec.describe Timekeeping::ServiceCommands do
  include_context "timekeeping entry writes"

  let(:advance_company) { timekeeping_arrange.company }

  def advance_command(route, target_id:, operation_id:, generation:)
    request = described_class::Request.new(route:, company_id: advance_company, actor_name: "invoice-boundary",
                                           target_id:, operation_id:, generation:)
    outcome = described_class.new.call(request)
    [outcome.status, JSON.parse(outcome.body)]
  end

  def advance_command_counts
    { audit_events: AuditEvent.count, outbox_snapshots: OutboxSnapshot.count,
      receipts: ServiceIdempotencyReceipt.count, versions: Entry.sum(:version) }
  end

  it "replays mark-billed and detach-entries with their original generation after the generation advances" do
    # "Add replay cases that complete an operation, advance the company's generation, and resend the
    # original request with its original generation. Cover prepare, commit, abort, mark-billed and
    # detach-entries, and assert the stored answer and unchanged business state."
    stale = [409, { "reason" => "stale_generation" }]
    original = timekeeping_arrange.current_generation
    billable = timekeeping_arrange.reserved_entry(company: advance_company, invoice_id: 501)
    attached = timekeeping_arrange.entry(
      company: advance_company, user: timekeeping_arrange.user(company: advance_company, role: "employee"),
      project: timekeeping_arrange.project(company: advance_company), agent_id: 77
    )
    bill_id = SecureRandom.uuid
    detach_id = SecureRandom.uuid
    billed = advance_command(:mark_billed, target_id: 501, operation_id: bill_id, generation: original)
    detached = advance_command(:detach_entries, target_id: 77, operation_id: detach_id, generation: original)
    expect([billed, detached]).to eq([[200, { "billed" => 1 }], [200, { "detached" => 1 }]])

    timekeeping_arrange.set_generation(original + 1)
    # Undo the first calls' writes so a replay that re-ran the work would visibly change them again.
    Entry.where(id: billable).update_all(bill_status: "unbilled")
    Entry.where(id: attached).update_all(agent_id: 77)
    expect([Entry.find(billable).bill_status, Entry.find(attached).agent_id]).to eq(["unbilled", 77])
    baseline = advance_command_counts

    expect(advance_command(:mark_billed, target_id: 501, operation_id: bill_id, generation: original)).to eq(billed)
    expect(advance_command(:detach_entries, target_id: 77, operation_id: detach_id, generation: original)).to eq(detached)
    expect(advance_command_counts).to eq(baseline)
    expect([Entry.find(billable).bill_status, Entry.find(attached).agent_id]).to eq(["unbilled", 77])

    # The same old generation under new operation ids is refused, so the replays above were sent stale.
    expect(advance_command(:mark_billed, target_id: 501, operation_id: SecureRandom.uuid, generation: original)).to eq(stale)
    expect(advance_command(:detach_entries, target_id: 77, operation_id: SecureRandom.uuid, generation: original)).to eq(stale)
    expect(advance_command_counts).to eq(baseline)
  end
end
