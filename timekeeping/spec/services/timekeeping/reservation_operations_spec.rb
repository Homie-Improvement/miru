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
                          actor_name: "invoice-boundary", generation: timekeeping_arrange.current_generation)
    Timekeeping::ReservationOperations::Request.new(
      route:, company_id: company, actor_name:, invoice_id:, operation_id:,
      generation:, disposition:, entry_ids:
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

  describe "a retained owner and a successor preparing the same entry" do
    # "commit makes the desired set the reservation set": whichever invoice
    # prepares the retained entry first holds it, the other is refused, and a
    # successful commit always leaves its whole desired set reserved.
    let(:provisional_elsewhere) do
      [409, { "reason" => "conflict", "conflicts" => [{ "entry_id" => x, "reason" => "provisional_elsewhere" }] }]
    end

    def held_with_disposition(entry_id)
      Reservation.where(entry_id:).order(:invoice_id).pluck(:invoice_id, :state, :disposition)
    end

    before { commit_entries([x], invoice_id: 501, disposition: "retained") }

    it "refuses the successor while the owner's active prepare holds the entry, then commits the owner's whole set" do
      owner_id = SecureRandom.uuid

      expect(run_operation(:prepare, operation_id: owner_id, invoice_id: 501, entry_ids: [x, y]).first).to eq(200)
      expect(run_operation(:prepare, operation_id: SecureRandom.uuid, invoice_id: 502, entry_ids: [x]))
        .to eq(provisional_elsewhere)

      expect(run_operation(:commit, operation_id: owner_id, invoice_id: 501))
        .to eq([200, { "reserved" => 1, "released" => 0 }])
      expect(held_with_disposition(x)).to eq([[501, "committed", "active"]])
      expect(held_with_disposition(y)).to eq([[501, "committed", "active"]])
    end

    it "refuses the owner while the successor's prepare holds the entry, then hands the entry to the successor" do
      successor_id = SecureRandom.uuid

      expect(run_operation(:prepare, operation_id: successor_id, invoice_id: 502, entry_ids: [x, y]).first).to eq(200)
      expect(run_operation(:prepare, operation_id: SecureRandom.uuid, invoice_id: 501, entry_ids: [x]))
        .to eq(provisional_elsewhere)

      expect(run_operation(:commit, operation_id: successor_id, invoice_id: 502))
        .to eq([200, { "reserved" => 2, "released" => 0 }])
      expect(held_with_disposition(x)).to eq([[502, "committed", "active"]])
      expect(held_with_disposition(y)).to eq([[502, "committed", "active"]])
    end

    it "leaves the retained reservation as it was when the owner's prepare aborts, so a successor may then take it" do
      owner_id = SecureRandom.uuid
      expect(run_operation(:prepare, operation_id: owner_id, invoice_id: 501, entry_ids: [x, y]).first).to eq(200)

      expect(run_operation(:abort, operation_id: owner_id, invoice_id: 501)).to eq([200, { "dropped" => 1 }])
      expect(held_with_disposition(x)).to eq([[501, "committed", "retained"]])
      expect(held(y)).to eq([])

      successor_id = SecureRandom.uuid
      expect(run_operation(:prepare, operation_id: successor_id, invoice_id: 502, entry_ids: [x]).first).to eq(200)
      expect(run_operation(:commit, operation_id: successor_id, invoice_id: 502))
        .to eq([200, { "reserved" => 1, "released" => 0 }])
      expect(held_with_disposition(x)).to eq([[502, "committed", "active"]])
    end

    it "keeps the entry retained when the owner prepares it again as retained" do
      owner_id = SecureRandom.uuid
      expect(run_operation(:prepare, operation_id: owner_id, invoice_id: 501, entry_ids: [x], disposition: "retained")
               .first).to eq(200)
      expect(run_operation(:prepare, operation_id: SecureRandom.uuid, invoice_id: 502, entry_ids: [x]))
        .to eq(provisional_elsewhere)

      expect(run_operation(:commit, operation_id: owner_id, invoice_id: 501))
        .to eq([200, { "reserved" => 0, "released" => 0 }])
      expect(held_with_disposition(x)).to eq([[501, "committed", "retained"]])
    end
  end

  # Generated by Descant: acceptance tests below.
  # A finished operation must answer from what it stored even after the generation moves on, because the
  # stored answer is read before the generation is checked. Each test ends with a control: the same old
  # generation under a new operation id is refused, which proves the replay really was sent stale.
  describe "a finished operation replayed with its original generation after the generation advances" do
    let(:stale_generation) { [409, { "reason" => "stale_generation" }] }

    it "replays a finished prepare from its operation row, still prepared, and changes nothing" do
      operation_id = SecureRandom.uuid
      original = timekeeping_arrange.current_generation
      first = run_operation(:prepare, operation_id:, entry_ids: [x])
      expect(first).to eq(
        [200, { "operation_id" => operation_id, "state" => "prepared", "entries" => [{ "entry_id" => x, "company_id" => company }] }]
      )
      timekeeping_arrange.set_generation(original + 1)
      expect(held(x)).to eq([[501, "provisional"]])
      baseline = reservation_row_counts

      expect(run_operation(:prepare, operation_id:, entry_ids: [x], generation: original)).to eq(first)
      expect(reservation_row_counts).to eq(baseline)
      expect(held(x)).to eq([[501, "provisional"]])
      expect(run_operation(:prepare, operation_id: SecureRandom.uuid, entry_ids: [x], generation: original))
        .to eq(stale_generation)
      expect(reservation_row_counts).to eq(baseline)
    end

    it "replays a finished commit from its receipt and changes nothing" do
      operation_id = SecureRandom.uuid
      original = timekeeping_arrange.current_generation
      run_operation(:prepare, operation_id:, entry_ids: [x])
      first = run_operation(:commit, operation_id:)
      expect(first).to eq([200, { "reserved" => 1, "released" => 0 }])
      timekeeping_arrange.set_generation(original + 1)
      expect(held(x)).to eq([[501, "committed"]])
      baseline = reservation_row_counts

      expect(run_operation(:commit, operation_id:, generation: original)).to eq(first)
      expect(reservation_row_counts).to eq(baseline)
      expect(held(x)).to eq([[501, "committed"]])
      expect(run_operation(:commit, operation_id: SecureRandom.uuid, generation: original)).to eq(stale_generation)
      expect(reservation_row_counts).to eq(baseline)
    end

    it "replays a finished abort from its receipt and changes nothing" do
      operation_id = SecureRandom.uuid
      original = timekeeping_arrange.current_generation
      run_operation(:prepare, operation_id:, entry_ids: [x])
      first = run_operation(:abort, operation_id:)
      expect(first).to eq([200, { "dropped" => 1 }])
      timekeeping_arrange.set_generation(original + 1)
      expect(held(x)).to eq([])
      baseline = reservation_row_counts

      expect(run_operation(:abort, operation_id:, generation: original)).to eq(first)
      expect(reservation_row_counts).to eq(baseline)
      expect(held(x)).to eq([])
      expect(run_operation(:abort, operation_id: SecureRandom.uuid, generation: original)).to eq(stale_generation)
      expect(reservation_row_counts).to eq(baseline)
    end
  end
end

# Generated by Descant: acceptance tests below.
RSpec.describe Timekeeping::ReservationOperations do
  include_context "timekeeping entry writes"

  let(:company) { timekeeping_arrange.company }
  let(:user) { timekeeping_arrange.user(company:, role: "employee") }
  let(:project) { timekeeping_arrange.project(company:) }
  let(:kept_entry) { timekeeping_arrange.entry(company:, user:, project:) }
  let(:released_entry) { timekeeping_arrange.entry(company:, user:, project:) }

  def unpublishable_reservation_call(route, operation_id:, entry_ids: [])
    request = Timekeeping::ReservationOperations::Request.new(
      route:, company_id: company, actor_name: "invoice-boundary", invoice_id: 501, operation_id:,
      generation: timekeeping_arrange.current_generation, disposition: "active", entry_ids:
    )
    outcome = described_class.new.call(request)
    [outcome.status, JSON.parse(outcome.body)]
  end

  it "refuses a prepare that would lock an entry with a stored unknown review status and leaves no operation" do
    bad = timekeeping_arrange.entry(company:, user:, project:)
    Entry.find(bad).update_column(:review_status, "unknown")
    before = reservation_row_counts
    version = Entry.find(bad).version
    operation_id = SecureRandom.uuid

    expect(unpublishable_reservation_call(:prepare, operation_id:, entry_ids: [bad])).to eq(
      [409, { "reason" => "unpublishable_entry", "entries" => [{ "entry_id" => bad, "fields" => ["review_status"] }] }]
    )
    expect(reservation_row_counts).to eq(before)
    expect(InvoiceOperation.where(operation_id:).count).to eq(0)
    expect(Reservation.where(entry_id: bad).count).to eq(0)
    expect(OutboxSnapshot.where(id: bad).count).to eq(0)
    expect(Entry.find(bad).version).to eq(version)
  end

  # The commit releases released_entry, which flips its locked flag and would republish its stored row.
  # Refusing it must roll back everything, and abort must stay possible because it flips only the
  # operation's own provisional entries, which are valid here.
  it "refuses a commit that would release a held entry with a bad stored source, keeps the operation prepared, and still lets it abort" do
    first = SecureRandom.uuid
    unpublishable_reservation_call(:prepare, operation_id: first, entry_ids: [kept_entry, released_entry])
    unpublishable_reservation_call(:commit, operation_id: first)
    second = SecureRandom.uuid
    expect(unpublishable_reservation_call(:prepare, operation_id: second, entry_ids: [kept_entry]).first).to eq(200)
    Entry.find(released_entry).update_column(:source, "legacy")
    before = { audits: AuditEvent.count, outbox: OutboxSnapshot.count, receipts: ServiceIdempotencyReceipt.count,
               versions: Entry.sum(:version), reservations: Reservation.order(:entry_id, :state).pluck(:entry_id, :state) }

    refused = unpublishable_reservation_call(:commit, operation_id: second)

    expect(refused).to eq(
      [409, { "reason" => "unpublishable_entry", "entries" => [{ "entry_id" => released_entry, "fields" => ["source"] }] }]
    )
    expect({ audits: AuditEvent.count, outbox: OutboxSnapshot.count, receipts: ServiceIdempotencyReceipt.count,
             versions: Entry.sum(:version), reservations: Reservation.order(:entry_id, :state).pluck(:entry_id, :state) })
      .to eq(before)
    expect(InvoiceOperation.find_by!(operation_id: second).state).to eq("prepared")

    expect(unpublishable_reservation_call(:abort, operation_id: second).first).to eq(200)
    expect(InvoiceOperation.find_by!(operation_id: second).state).to eq("aborted")
    expect(Reservation.where(entry_id: released_entry).pluck(:state)).to eq(["committed"])
  end

  # Abort unlocks the operation's own provisional entry, so a bad value stored on it after prepare is
  # refused like any other republish, and the abort's deletes roll back with it.
  it "refuses an abort that would unlock a provisional entry with a bad stored source and restores the prepared state" do
    operation_id = SecureRandom.uuid
    expect(unpublishable_reservation_call(:prepare, operation_id:, entry_ids: [kept_entry]).first).to eq(200)
    Entry.find(kept_entry).update_column(:source, "legacy")
    before = { audits: AuditEvent.count, outbox: OutboxSnapshot.count, receipts: ServiceIdempotencyReceipt.count,
               version: Entry.find(kept_entry).version,
               reservations: Reservation.where(entry_id: kept_entry).pluck(:invoice_id, :state) }

    refused = unpublishable_reservation_call(:abort, operation_id:)

    expect(refused).to eq(
      [409, { "reason" => "unpublishable_entry", "entries" => [{ "entry_id" => kept_entry, "fields" => ["source"] }] }]
    )
    expect({ audits: AuditEvent.count, outbox: OutboxSnapshot.count, receipts: ServiceIdempotencyReceipt.count,
             version: Entry.find(kept_entry).version,
             reservations: Reservation.where(entry_id: kept_entry).pluck(:invoice_id, :state) }).to eq(before)
    expect(before.fetch(:reservations)).to eq([[501, "provisional"]])
    expect(InvoiceOperation.find_by!(operation_id:).state).to eq("prepared")
  end
end
