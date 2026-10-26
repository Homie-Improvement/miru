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
end

# Generated by Descant: acceptance tests below.
require "rails_helper"

RSpec.describe Timekeeping::ReservationOperations do
  include_context "timekeeping entry writes"

  # "Add replay cases that complete an operation, advance the company's generation, and resend the original
  # request with its original generation. Cover prepare, commit, abort, mark-billed and detach-entries, and
  # assert the stored answer and unchanged business state."
  it "replays a finished commit from its receipt after the generation advances" do
    company = timekeeping_arrange.company
    x = timekeeping_arrange.entry(company:, user: timekeeping_arrange.user(company:, role: "employee"),
                                  project: timekeeping_arrange.project(company:))
    send_operation = lambda do |route, operation_id, generation, entry_ids = []|
      request = described_class::Request.new(route:, company_id: company, actor_name: "invoice-boundary", invoice_id: 501,
                                             operation_id:, generation:, disposition: "active", entry_ids:)
      outcome = described_class.new.call(request)
      [outcome.status, JSON.parse(outcome.body)]
    end
    row_counts = lambda do
      [Reservation.count, InvoiceOperation.count, AuditEvent.count, OutboxSnapshot.count,
       ServiceIdempotencyReceipt.count, Entry.sum(:version)]
    end
    held_x = -> { Reservation.where(entry_id: x).order(:invoice_id).pluck(:invoice_id, :state) }
    operation_id = SecureRandom.uuid
    original = timekeeping_arrange.current_generation

    expect(send_operation.call(:prepare, operation_id, original, [x]).first).to eq(200)
    first = send_operation.call(:commit, operation_id, original)
    expect(first).to eq([200, { "reserved" => 1, "released" => 0 }])
    timekeeping_arrange.set_generation(original + 1)
    expect(held_x.call).to eq([[501, "committed"]])
    baseline = row_counts.call

    expect(send_operation.call(:commit, operation_id, original)).to eq(first)
    expect(row_counts.call).to eq(baseline)
    expect(held_x.call).to eq([[501, "committed"]])
    # Control: the original generation really is stale for work that was never finished.
    expect(send_operation.call(:commit, SecureRandom.uuid, original)).to eq([409, { "reason" => "stale_generation" }])
    expect(row_counts.call).to eq(baseline)
  end
end

require "rails_helper"

RSpec.describe Timekeeping::ReservationOperations do
  include_context "timekeeping entry writes"

  # "Add replay cases that complete an operation, advance the company's generation, and resend the original
  # request with its original generation. Cover prepare, commit, abort, mark-billed and detach-entries, and
  # assert the stored answer and unchanged business state."
  it "replays a finished abort from its receipt after the generation advances" do
    company = timekeeping_arrange.company
    x = timekeeping_arrange.entry(company:, user: timekeeping_arrange.user(company:, role: "employee"),
                                  project: timekeeping_arrange.project(company:))
    send_operation = lambda do |route, operation_id, generation, entry_ids = []|
      request = described_class::Request.new(route:, company_id: company, actor_name: "invoice-boundary", invoice_id: 501,
                                             operation_id:, generation:, disposition: "active", entry_ids:)
      outcome = described_class.new.call(request)
      [outcome.status, JSON.parse(outcome.body)]
    end
    row_counts = lambda do
      [Reservation.count, InvoiceOperation.count, AuditEvent.count, OutboxSnapshot.count,
       ServiceIdempotencyReceipt.count, Entry.sum(:version)]
    end
    held_x = -> { Reservation.where(entry_id: x).order(:invoice_id).pluck(:invoice_id, :state) }
    operation_id = SecureRandom.uuid
    original = timekeeping_arrange.current_generation

    expect(send_operation.call(:prepare, operation_id, original, [x]).first).to eq(200)
    first = send_operation.call(:abort, operation_id, original)
    expect(first).to eq([200, { "dropped" => 1 }])
    timekeeping_arrange.set_generation(original + 1)
    expect(held_x.call).to eq([])
    baseline = row_counts.call

    expect(send_operation.call(:abort, operation_id, original)).to eq(first)
    expect(row_counts.call).to eq(baseline)
    expect(held_x.call).to eq([])
    # Control: the original generation really is stale for work that was never finished.
    expect(send_operation.call(:abort, SecureRandom.uuid, original)).to eq([409, { "reason" => "stale_generation" }])
    expect(row_counts.call).to eq(baseline)
  end
end

require "rails_helper"

RSpec.describe Timekeeping::ReservationOperations do
  include_context "timekeeping entry writes"

  # "Add replay cases that complete an operation, advance the company's generation, and resend the original
  # request with its original generation. Cover prepare, commit, abort, mark-billed and detach-entries, and
  # assert the stored answer and unchanged business state."
  it "replays a finished prepare from its operation row after the generation advances" do
    company = timekeeping_arrange.company
    x = timekeeping_arrange.entry(company:, user: timekeeping_arrange.user(company:, role: "employee"),
                                  project: timekeeping_arrange.project(company:))
    send_prepare = lambda do |operation_id, generation|
      request = described_class::Request.new(route: :prepare, company_id: company, actor_name: "invoice-boundary",
                                             invoice_id: 501, operation_id:, generation:, disposition: "active",
                                             entry_ids: [x])
      outcome = described_class.new.call(request)
      [outcome.status, JSON.parse(outcome.body)]
    end
    row_counts = lambda do
      [Reservation.count, InvoiceOperation.count, AuditEvent.count, OutboxSnapshot.count,
       ServiceIdempotencyReceipt.count, Entry.sum(:version)]
    end
    held_x = -> { Reservation.where(entry_id: x).order(:invoice_id).pluck(:invoice_id, :state) }
    operation_id = SecureRandom.uuid
    original = timekeeping_arrange.current_generation

    # The prepare answer carries the operation's current state; it stays "prepared" because nothing commits it.
    first = send_prepare.call(operation_id, original)
    expect(first).to eq(
      [200, { "operation_id" => operation_id, "state" => "prepared", "entries" => [{ "entry_id" => x, "company_id" => company }] }]
    )
    timekeeping_arrange.set_generation(original + 1)
    expect(held_x.call).to eq([[501, "provisional"]])
    baseline = row_counts.call

    expect(send_prepare.call(operation_id, original)).to eq(first)
    expect(row_counts.call).to eq(baseline)
    expect(held_x.call).to eq([[501, "provisional"]])
    # Control: the original generation really is stale for work that was never finished.
    expect(send_prepare.call(SecureRandom.uuid, original)).to eq([409, { "reason" => "stale_generation" }])
    expect(row_counts.call).to eq(baseline)
  end
end

require "rails_helper"
require "webmock/rspec"

RSpec.describe Timekeeping::ReservationOperations do
  include_context "timekeeping entry writes"

  it "replays a finished commit with its original generation after the generation advances, changing nothing" do
    company = timekeeping_arrange.company
    entry = timekeeping_arrange.entry(company:, user: timekeeping_arrange.user(company:, role: "employee"),
                                      project: timekeeping_arrange.project(company:))
    send_operation = lambda do |route, operation_id, generation|
      request = described_class::Request.new(route:, company_id: company, actor_name: "invoice-boundary", invoice_id: 501,
                                             operation_id:, generation:, disposition: "active", entry_ids: [entry])
      outcome = described_class.new.call(request)
      [outcome.status, JSON.parse(outcome.body)]
    end
    row_counts = lambda do
      { reservations: Reservation.count, operations: InvoiceOperation.count, audit_events: AuditEvent.count,
        outbox_snapshots: OutboxSnapshot.count, receipts: ServiceIdempotencyReceipt.count, versions: Entry.sum(:version) }
    end
    operation_id = SecureRandom.uuid
    original = timekeeping_arrange.current_generation
    expect(send_operation.call(:prepare, operation_id, original).first).to eq(200)
    first = send_operation.call(:commit, operation_id, original)
    expect(first.first).to eq(200)
    timekeeping_arrange.set_generation(original + 1)
    expect(Reservation.where(entry_id: entry).pluck(:invoice_id, :state)).to eq([[501, "committed"]])
    baseline = row_counts.call

    # "Add replay cases that complete an operation, advance the company's generation, and resend the original request with its original generation."
    expect(send_operation.call(:commit, operation_id, original)).to eq(first)
    expect(row_counts.call).to eq(baseline)
    expect(Reservation.where(entry_id: entry).pluck(:invoice_id, :state)).to eq([[501, "committed"]])
    # The same old generation under a new operation id is refused, so the replay really was sent stale.
    expect(send_operation.call(:commit, SecureRandom.uuid, original)).to eq([409, { "reason" => "stale_generation" }])
  end
end

require "rails_helper"
require "webmock/rspec"

RSpec.describe Timekeeping::ReservationOperations do
  include_context "timekeeping entry writes"

  it "replays a finished abort with its original generation after the generation advances, changing nothing" do
    company = timekeeping_arrange.company
    entry = timekeeping_arrange.entry(company:, user: timekeeping_arrange.user(company:, role: "employee"),
                                      project: timekeeping_arrange.project(company:))
    send_operation = lambda do |route, operation_id, generation|
      request = described_class::Request.new(route:, company_id: company, actor_name: "invoice-boundary", invoice_id: 501,
                                             operation_id:, generation:, disposition: "active", entry_ids: [entry])
      outcome = described_class.new.call(request)
      [outcome.status, JSON.parse(outcome.body)]
    end
    row_counts = lambda do
      { reservations: Reservation.count, operations: InvoiceOperation.count, audit_events: AuditEvent.count,
        outbox_snapshots: OutboxSnapshot.count, receipts: ServiceIdempotencyReceipt.count, versions: Entry.sum(:version) }
    end
    operation_id = SecureRandom.uuid
    original = timekeeping_arrange.current_generation
    expect(send_operation.call(:prepare, operation_id, original).first).to eq(200)
    first = send_operation.call(:abort, operation_id, original)
    expect(first).to eq([200, { "dropped" => 1 }])
    timekeeping_arrange.set_generation(original + 1)
    expect(Reservation.where(entry_id: entry).pluck(:invoice_id, :state)).to eq([])
    baseline = row_counts.call

    # "Add replay cases that complete an operation, advance the company's generation, and resend the original request with its original generation."
    expect(send_operation.call(:abort, operation_id, original)).to eq(first)
    expect(row_counts.call).to eq(baseline)
    expect(Reservation.where(entry_id: entry).pluck(:invoice_id, :state)).to eq([])
    # The same old generation under a new operation id is refused, so the replay really was sent stale.
    expect(send_operation.call(:abort, SecureRandom.uuid, original)).to eq([409, { "reason" => "stale_generation" }])
  end
end

require "rails_helper"
require "webmock/rspec"

RSpec.describe Timekeeping::ReservationOperations do
  include_context "timekeeping entry writes"

  it "replays a finished prepare with its original generation after the generation advances, changing nothing" do
    company = timekeeping_arrange.company
    entry = timekeeping_arrange.entry(company:, user: timekeeping_arrange.user(company:, role: "employee"),
                                      project: timekeeping_arrange.project(company:))
    send_operation = lambda do |route, operation_id, generation|
      request = described_class::Request.new(route:, company_id: company, actor_name: "invoice-boundary", invoice_id: 501,
                                             operation_id:, generation:, disposition: "active", entry_ids: [entry])
      outcome = described_class.new.call(request)
      [outcome.status, JSON.parse(outcome.body)]
    end
    row_counts = lambda do
      { reservations: Reservation.count, operations: InvoiceOperation.count, audit_events: AuditEvent.count,
        outbox_snapshots: OutboxSnapshot.count, receipts: ServiceIdempotencyReceipt.count, versions: Entry.sum(:version) }
    end
    operation_id = SecureRandom.uuid
    original = timekeeping_arrange.current_generation
    first = send_operation.call(:prepare, operation_id, original)
    expect(first).to eq(
      [200, { "operation_id" => operation_id, "state" => "prepared", "entries" => [{ "entry_id" => entry, "company_id" => company }] }]
    )
    timekeeping_arrange.set_generation(original + 1)
    expect(Reservation.where(entry_id: entry).pluck(:invoice_id, :state)).to eq([[501, "provisional"]])
    baseline = row_counts.call

    # "Add replay cases that complete an operation, advance the company's generation, and resend the original request with its original generation."
    expect(send_operation.call(:prepare, operation_id, original)).to eq(first)
    expect(row_counts.call).to eq(baseline)
    expect(Reservation.where(entry_id: entry).pluck(:invoice_id, :state)).to eq([[501, "provisional"]])
    # The same old generation under a new operation id is refused, so the replay really was sent stale.
    expect(send_operation.call(:prepare, SecureRandom.uuid, original)).to eq([409, { "reason" => "stale_generation" }])
  end
end

RSpec.describe Timekeeping::ReservationOperations do
  include_context "timekeeping entry writes"

  let(:advance_company) { timekeeping_arrange.company }
  let(:advance_user) { timekeeping_arrange.user(company: advance_company, role: "employee") }
  let(:advance_project) { timekeeping_arrange.project(company: advance_company) }

  def advance_entry
    timekeeping_arrange.entry(company: advance_company, user: advance_user, project: advance_project)
  end

  def advance_run(route, operation_id:, generation:, invoice_id: 501, entry_ids: [])
    request = Timekeeping::ReservationOperations::Request.new(
      route:, company_id: advance_company, actor_name: "invoice-boundary", invoice_id:, operation_id:,
      generation:, disposition: "active", entry_ids:
    )
    outcome = described_class.new.call(request)
    [outcome.status, JSON.parse(outcome.body)]
  end

  def advance_held(entry_id)
    Reservation.where(entry_id:).order(:invoice_id).pluck(:invoice_id, :state)
  end

  def advance_counts
    { reservations: Reservation.count, operations: InvoiceOperation.count, audit_events: AuditEvent.count,
      outbox_snapshots: OutboxSnapshot.count, receipts: ServiceIdempotencyReceipt.count, versions: Entry.sum(:version) }
  end

  it "replays prepare, commit and abort with their original generation after the generation advances" do
    # "Add replay cases that complete an operation, advance the company's generation, and resend the
    # original request with its original generation. Cover prepare, commit, abort, mark-billed and
    # detach-entries, and assert the stored answer and unchanged business state."
    stale = [409, { "reason" => "stale_generation" }]
    original = timekeeping_arrange.current_generation
    prepared_entry = advance_entry
    committed_entry = advance_entry
    aborted_entry = advance_entry

    prepare_id = SecureRandom.uuid
    prepared = advance_run(:prepare, operation_id: prepare_id, invoice_id: 601, entry_ids: [prepared_entry], generation: original)
    commit_id = SecureRandom.uuid
    expect(advance_run(:prepare, operation_id: commit_id, invoice_id: 602, entry_ids: [committed_entry], generation: original).first).to eq(200)
    committed = advance_run(:commit, operation_id: commit_id, invoice_id: 602, generation: original)
    abort_id = SecureRandom.uuid
    expect(advance_run(:prepare, operation_id: abort_id, invoice_id: 603, entry_ids: [aborted_entry], generation: original).first).to eq(200)
    aborted = advance_run(:abort, operation_id: abort_id, invoice_id: 603, generation: original)
    expect([prepared.first, committed, aborted]).to eq([200, [200, { "reserved" => 1, "released" => 0 }], [200, { "dropped" => 1 }]])

    timekeeping_arrange.set_generation(original + 1)
    baseline = advance_counts
    held_before = [advance_held(prepared_entry), advance_held(committed_entry), advance_held(aborted_entry)]
    expect(held_before).to eq([[[601, "provisional"]], [[602, "committed"]], []])

    expect(advance_run(:prepare, operation_id: prepare_id, invoice_id: 601, entry_ids: [prepared_entry], generation: original)).to eq(prepared)
    expect(advance_run(:commit, operation_id: commit_id, invoice_id: 602, generation: original)).to eq(committed)
    expect(advance_run(:abort, operation_id: abort_id, invoice_id: 603, generation: original)).to eq(aborted)
    expect(advance_counts).to eq(baseline)
    expect([advance_held(prepared_entry), advance_held(committed_entry), advance_held(aborted_entry)]).to eq(held_before)

    # The same old generation under new operation ids is refused, so the replays above were sent stale.
    expect(advance_run(:prepare, operation_id: SecureRandom.uuid, invoice_id: 604, entry_ids: [advance_entry], generation: original)).to eq(stale)
    expect(advance_run(:commit, operation_id: SecureRandom.uuid, invoice_id: 602, generation: original)).to eq(stale)
    expect(advance_run(:abort, operation_id: SecureRandom.uuid, invoice_id: 603, generation: original)).to eq(stale)
  end
end
