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

  # Generated by Descant: acceptance tests below.
  # A finished command must answer from its receipt even after the generation moves on, because the receipt
  # is read before the generation is checked. Each test undoes the first call's write, so a replay that ran
  # the work again would show, and ends with a control: the same old generation under a new operation id is
  # refused, which proves the replay really was sent stale.
  describe "a finished command replayed with its original generation after the generation advances" do
    let(:stale_generation) { [409, { "reason" => "stale_generation" }] }

    it "replays a finished mark-billed from its receipt and bills nothing again" do
      billable = timekeeping_arrange.reserved_entry(company:, invoice_id: 501)
      operation_id = SecureRandom.uuid
      original = timekeeping_arrange.current_generation
      first = service_command(:mark_billed, target_id: 501, operation_id:)
      expect(first).to eq([200, { "billed" => 1 }])
      timekeeping_arrange.set_generation(original + 1)
      Entry.where(id: billable).update_all(bill_status: "unbilled")
      expect(Entry.find(billable).bill_status).to eq("unbilled")
      baseline = command_row_counts

      expect(service_command(:mark_billed, target_id: 501, operation_id:, generation: original)).to eq(first)
      expect(command_row_counts).to eq(baseline)
      expect(Entry.find(billable).bill_status).to eq("unbilled")
      expect(service_command(:mark_billed, target_id: 501, generation: original)).to eq(stale_generation)
      expect(command_row_counts).to eq(baseline)
    end

    it "replays a finished detach-entries from its receipt and detaches nothing again" do
      attached = plain_entry(company, agent_id: 77)
      operation_id = SecureRandom.uuid
      original = timekeeping_arrange.current_generation
      first = service_command(:detach_entries, target_id: 77, operation_id:)
      expect(first).to eq([200, { "detached" => 1 }])
      timekeeping_arrange.set_generation(original + 1)
      Entry.where(id: attached).update_all(agent_id: 77)
      expect(Entry.find(attached).agent_id).to eq(77)
      baseline = command_row_counts

      expect(service_command(:detach_entries, target_id: 77, operation_id:, generation: original)).to eq(first)
      expect(command_row_counts).to eq(baseline)
      expect(Entry.find(attached).agent_id).to eq(77)
      expect(service_command(:detach_entries, target_id: 77, generation: original)).to eq(stale_generation)
      expect(command_row_counts).to eq(baseline)
    end
  end

  # Generated by Descant: acceptance tests below.
  # "mark_billed, detach_entries and entry updates that omit source republish whatever is stored, so a bad
  # stored value (for example from the checkpoint load) still reaches the outbox and stops delivery."
  it "refuses a mark-billed over a stored bad source with nothing kept, then bills on a retry with the same operation id once repaired" do
    billable = timekeeping_arrange.reserved_entry(company:, invoice_id: 501)
    Entry.find(billable).update_column(:source, "legacy")
    operation_id = SecureRandom.uuid
    before = command_row_counts

    expect(service_command(:mark_billed, target_id: 501, operation_id:))
      .to eq([409, { "reason" => "unpublishable_entry", "entries" => [{ "entry_id" => billable, "fields" => ["source"] }] }])
    expect(Entry.find(billable).bill_status).to eq("unbilled")
    expect(command_row_counts).to eq(before)

    Entry.find(billable).update_column(:source, "manual")

    expect(service_command(:mark_billed, target_id: 501, operation_id:)).to eq([200, { "billed" => 1 }])
    expect(Entry.find(billable).bill_status).to eq("billed")
    expect(OutboxSnapshot.where(id: billable).pluck(:bill_status, :source)).to eq([["billed", "manual"]])
    expect(ServiceIdempotencyReceipt.count).to eq(before[:receipts] + 1)
  end

  # One bad row refuses the whole batch: the valid entry beside it is not detached or published either.
  it "refuses a detach-entries batch when one entry has a stored infinite duration and detaches none of them" do
    valid = plain_entry(company, agent_id: 77)
    bad = plain_entry(company, agent_id: 77)
    Entry.find(bad).update_column(:duration, Float::INFINITY)
    before = command_row_counts

    expect(service_command(:detach_entries, target_id: 77))
      .to eq([409, { "reason" => "unpublishable_entry", "entries" => [{ "entry_id" => bad, "fields" => ["duration"] }] }])
    expect(Entry.where(id: [valid, bad]).order(:id).pluck(:agent_id)).to eq([77, 77])
    expect(command_row_counts).to eq(before)
  end

  # One bad entry must refuse the whole batch: inserting the valid entry and skipping the bad one would leave
  # a partial write.
  it "refuses a mark-billed batch whole when one of its entries holds a bad stored source, billing and publishing neither" do
    valid = timekeeping_arrange.reserved_entry(company:, invoice_id: 501)
    bad = timekeeping_arrange.reserved_entry(company:, invoice_id: 501)
    Entry.find(bad).update_column(:source, "legacy")
    before = command_row_counts

    expect(service_command(:mark_billed, target_id: 501))
      .to eq([409, { "reason" => "unpublishable_entry", "entries" => [{ "entry_id" => bad, "fields" => ["source"] }] }])
    expect(Entry.where(id: [valid, bad]).order(:id).pluck(:bill_status)).to eq(%w[unbilled unbilled])
    expect(command_row_counts).to eq(before)
  end

  # A refusal must keep no receipt: if it did, the retry below would replay the refusal (or a stored
  # success) and the entry would never be detached or published.
  it "runs a refused detach again as a first attempt under the same operation id once the stored value is fixed" do
    entry = plain_entry(company, agent_id: 77)
    Entry.find(entry).update_column(:duration, Float::INFINITY)
    operation_id = SecureRandom.uuid

    status, body = service_command(:detach_entries, target_id: 77, operation_id:)
    expect([status, body.fetch("reason")]).to eq([409, "unpublishable_entry"])
    expect(ServiceIdempotencyReceipt.where(key: operation_id).count).to eq(0)
    expect(Entry.find(entry).agent_id).to eq(77)

    Entry.find(entry).update_column(:duration, 1.5)

    expect(service_command(:detach_entries, target_id: 77, operation_id:)).to eq([200, { "detached" => 1 }])
    expect(Entry.find(entry).agent_id).to be_nil
    expect(OutboxSnapshot.where(id: entry).count).to eq(1)
  end
end
