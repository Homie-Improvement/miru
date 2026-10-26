# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

RSpec.describe Timekeeping::ReservationOperations do
  include_context "timekeeping entry writes"

  let(:company) { timekeeping_arrange.company }
  let(:user) { timekeeping_arrange.user(company:, role: "employee") }
  let(:project) { timekeeping_arrange.project(company:) }
  let(:x) { timekeeping_arrange.entry(company:, user:, project:) }
  let(:y) { timekeeping_arrange.entry(company:, user:, project:) }

  def reservation_request(route, operation_id:, invoice_id: 501, entry_ids: [], disposition: "active",
                          actor_name: "invoice-boundary")
    Timekeeping::ReservationOperations::Request.new(
      route:, company_id: company, actor_name:, invoice_id:, operation_id:,
      generation: timekeeping_arrange.current_generation, disposition:, entry_ids:
    )
  end

  def run_operation(route, **options)
    outcome = described_class.new.call(reservation_request(route, **options))
    [outcome.status, JSON.parse(outcome.body)]
  end

  # Prepares and commits entry_ids for the invoice under a new operation id.
  def commit_entries(entry_ids, invoice_id: 501, disposition: "active")
    operation_id = SecureRandom.uuid
    expect(run_operation(:prepare, operation_id:, invoice_id:, entry_ids:, disposition:).first).to eq(200)
    run_operation(:commit, operation_id:, invoice_id:)
  end

  def held(entry_id)
    Reservation.where(entry_id:).order(:invoice_id).pluck(:invoice_id, :state)
  end

  def reservation_row_counts
    { reservations: Reservation.count, operations: InvoiceOperation.count, audit_events: AuditEvent.count,
      outbox_snapshots: OutboxSnapshot.count, receipts: ServiceIdempotencyReceipt.count, versions: Entry.sum(:version) }
  end

  it "leaves no reservation, operation, audit or outbox row when the outbox insert fails after the reservation write" do
    x
    before = reservation_row_counts
    allow(OutboxSnapshot).to receive(:insert_all!).and_raise(ActiveRecord::StatementInvalid, "outbox down")

    expect { run_operation(:prepare, operation_id: SecureRandom.uuid, entry_ids: [x]) }
      .to raise_error(ActiveRecord::StatementInvalid, "outbox down")
    expect(reservation_row_counts).to eq(before)
  end

  it "keeps no prepared row after a conflict, so the same operation id succeeds with a corrected entry set" do
    commit_entries([x], invoice_id: 502)
    y
    before = reservation_row_counts
    operation_id = SecureRandom.uuid

    refused = run_operation(:prepare, operation_id:, entry_ids: [y, x])

    expect(refused).to eq([409, { "reason" => "conflict", "conflicts" => [{ "entry_id" => x, "reason" => "on_another_invoice" }] }])
    expect(reservation_row_counts).to eq(before)
    expect(run_operation(:prepare, operation_id:, entry_ids: [y])).to eq(
      [200, { "operation_id" => operation_id, "state" => "prepared", "entries" => [{ "entry_id" => y, "company_id" => company }] }]
    )
  end

  it "changes no row count or version when commit, abort and prepare are replayed after commit" do
    operation_id = SecureRandom.uuid
    run_operation(:prepare, operation_id:, entry_ids: [x])
    first = run_operation(:commit, operation_id:)
    after_commit = reservation_row_counts

    expect(run_operation(:commit, operation_id:)).to eq(first)
    expect(run_operation(:abort, operation_id:)).to eq([200, { "dropped" => 0 }])
    expect(run_operation(:prepare, operation_id:, entry_ids: [x]).last.fetch("state")).to eq("committed")
    expect(reservation_row_counts.except(:receipts)).to eq(after_commit.except(:receipts))
    expect(held(x)).to eq([[501, "committed"]])
  end

  it "reserves separately for another service using the same operation id, and its abort keeps the first service's rows" do
    operation_id = SecureRandom.uuid
    run_operation(:prepare, operation_id:, entry_ids: [x])

    other = run_operation(:prepare, operation_id:, invoice_id: 502, entry_ids: [y], actor_name: "agent-destroy")

    expect(other.first).to eq(200)
    expect(run_operation(:abort, operation_id:, invoice_id: 502, actor_name: "agent-destroy")).to eq([200, { "dropped" => 1 }])
    expect([held(x), held(y)]).to eq([[[501, "provisional"]], []])
  end

  it "commits only the set prepare stored, ignoring entries sent with the commit" do
    operation_id = SecureRandom.uuid
    run_operation(:prepare, operation_id:, entry_ids: [x])

    expect(run_operation(:commit, operation_id:, entry_ids: [x, y])).to eq([200, { "reserved" => 1, "released" => 0 }])
    expect([held(x), held(y)]).to eq([[[501, "committed"]], []])
  end

  it "releases nothing on a retained commit whose stored set drops an entry" do
    commit_entries([x, y])

    expect(commit_entries([x], disposition: "retained")).to eq([200, { "reserved" => 0, "released" => 0 }])
    expect(held(y)).to eq([[501, "committed"]])
    expect(Reservation.where(invoice_id: 501).distinct.pluck(:disposition)).to eq(["retained"])
  end

  it "writes no audit, outbox or version change when a provisional reservation becomes committed" do
    operation_id = SecureRandom.uuid
    run_operation(:prepare, operation_id:, entry_ids: [x])
    before = [AuditEvent.where(entry_id: x).count, OutboxSnapshot.where(id: x).count, Entry.find(x).version]

    run_operation(:commit, operation_id:)

    expect([AuditEvent.where(entry_id: x).count, OutboxSnapshot.where(id: x).count, Entry.find(x).version]).to eq(before)
  end

  it "flips locked, raises the version and writes one service audit row and one snapshot when a commit releases an entry" do
    commit_entries([x, y])
    version = Entry.find(y).version
    audits = AuditEvent.where(entry_id: y).count

    expect(commit_entries([x])).to eq([200, { "reserved" => 0, "released" => 1 }])

    expect(Entry.find(y).version).to eq(version + 1)
    expect(AuditEvent.where(entry_id: y).count).to eq(audits + 1)
    audit = AuditEvent.where(entry_id: y).order(:id).last
    expect([audit.actor_type, audit.actor_name, audit.actor_id, audit.action, audit.before, audit.after])
      .to eq(["service", "invoice-boundary", nil, "commit", { "locked" => true }, { "locked" => false }])
    snapshot = OutboxSnapshot.where(id: y).order(:outbox_position).last
    expect([snapshot.locked, snapshot.version]).to eq([false, version + 1])
  end

  # An entry another kept invoice holds is refused at prepare, so a successor
  # must not take it at commit once its retained owner has become active again.
  it "keeps an entry for a retained owner that became active before its successor commits" do
    commit_entries([x], invoice_id: 501, disposition: "retained")
    owner_id = SecureRandom.uuid
    successor_id = SecureRandom.uuid

    expect(run_operation(:prepare, operation_id: owner_id, invoice_id: 501, entry_ids: [x]).first).to eq(200)
    expect(run_operation(:prepare, operation_id: successor_id, invoice_id: 502, entry_ids: [x]).first).to eq(200)
    expect(run_operation(:commit, operation_id: owner_id, invoice_id: 501)).to eq([200, { "reserved" => 0, "released" => 0 }])

    expect(run_operation(:commit, operation_id: successor_id, invoice_id: 502))
      .to eq([200, { "reserved" => 0, "released" => 0 }])
    expect(Reservation.where(entry_id: x).pluck(:invoice_id, :state, :disposition)).to eq([[501, "committed", "active"]])
  end
end
