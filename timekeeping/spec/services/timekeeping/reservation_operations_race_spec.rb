# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

# Two reservation operations on two connections, with the first held at a
# named step of its transaction while the second runs, so each race meets at
# a known point instead of depending on thread timing.
RSpec.describe Timekeeping::ReservationOperations, "under concurrent requests" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # Runs before the shared context's truncate; reservations go in the same
  # statement because they reference invoice_operations.
  after do
    ApplicationRecord.connection.execute("TRUNCATE reservations, invoice_operations, service_idempotency_receipts")
  end

  let(:wait_seconds) { 10 }

  let(:company) { timekeeping_arrange.company }
  let(:user) { timekeeping_arrange.user(company:, role: "employee") }
  let(:project) { timekeeping_arrange.project(company:) }
  let(:entry_id) { timekeeping_arrange.entry(company:, user:, project:) }

  def race_request(route, operation_id:, invoice_id: 501, entry_ids: [])
    Timekeeping::ReservationOperations::Request.new(
      route:, company_id: company, actor_name: "invoice-boundary", invoice_id:, operation_id:,
      generation: timekeeping_arrange.current_generation, disposition: "active", entry_ids:
    )
  end

  def answer(outcome)
    [outcome.status, JSON.parse(outcome.body)]
  end

  def on_own_reservation_connection(backend_pids, &block)
    Thread.new do
      ApplicationRecord.connection_pool.with_connection do |connection|
        backend_pids.push(connection.select_value("SELECT pg_backend_pid()"))
        block.call
      end
    end
  end

  # Runs the first request until it reaches hold_at, then the second on
  # another connection, and lets the first go on only once the server reports
  # the second blocked by the first one's locks. Returns both answers.
  def race_reservations(first_request, second_request, hold_at:)
    reached = Queue.new
    release = Queue.new
    first_pid = Queue.new
    other_pid = Queue.new
    checkpoint = lambda do |step|
      next unless step == hold_at

      reached << true
      release.pop
    end
    first = on_own_reservation_connection(first_pid) { described_class.new(checkpoint:).call(first_request) }
    expect(reached.pop(timeout: wait_seconds)).to be(true)
    other = on_own_reservation_connection(other_pid) { described_class.new.call(second_request) }
    blocked = reservation_blocked_by?(other_pid.pop(timeout: wait_seconds), first_pid.pop(timeout: wait_seconds))
    release << true
    results = [first.join(wait_seconds)&.value, other.join(wait_seconds)&.value]
    expect(blocked).to be(true), "the second request never waited on the first one's lock"
    results.map { |outcome| answer(outcome) }
  end

  def reservation_blocked_by?(waiting_pid, holding_pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      blocked = ApplicationRecord.connection.select_value(
        ApplicationRecord.sanitize_sql_array(["SELECT ? = ANY(pg_blocking_pids(?))", holding_pid, waiting_pid])
      )
      return true if blocked

      sleep 0.02
    end
    false
  end

  it "answers two prepares of one entry for different invoices with one 200 and one provisional_elsewhere conflict" do
    first = race_request(:prepare, operation_id: SecureRandom.uuid, entry_ids: [entry_id])
    second = race_request(:prepare, operation_id: SecureRandom.uuid, invoice_id: 502, entry_ids: [entry_id])

    first_answer, second_answer = race_reservations(first, second, hold_at: :rows_locked)

    expect(first_answer.first).to eq(200)
    expect(second_answer).to eq(
      [409, { "reason" => "conflict", "conflicts" => [{ "entry_id" => entry_id, "reason" => "provisional_elsewhere" }] }]
    )
    expect(Reservation.where(entry_id:).pluck(:invoice_id, :state)).to eq([[501, "provisional"]])
  end

  # Correctness only: the one-prepared-per-invoice index and its backstop also
  # give this answer.
  it "answers a second prepare for the same invoice with unresolved_operation naming the first operation" do
    first_id = SecureRandom.uuid
    first = race_request(:prepare, operation_id: first_id, entry_ids: [entry_id])
    second = race_request(:prepare, operation_id: SecureRandom.uuid, entry_ids: [entry_id])

    first_answer, second_answer = race_reservations(first, second, hold_at: :operation_checked)

    expect(first_answer.first).to eq(200)
    expect(second_answer).to eq(
      [409, { "reason" => "unresolved_operation", "operation_id" => first_id, "retryable" => true }]
    )
    expect(InvoiceOperation.pluck(:operation_id)).to eq([first_id])
  end

  it "lets the first of a racing commit and abort decide the one terminal state" do
    operation_id = SecureRandom.uuid
    expect(described_class.new.call(race_request(:prepare, operation_id:, entry_ids: [entry_id])).status).to eq(200)

    committed, aborted = race_reservations(race_request(:commit, operation_id:), race_request(:abort, operation_id:),
                                           hold_at: :operation_checked)

    expect([committed, aborted]).to eq([[200, { "reserved" => 1, "released" => 0 }], [200, { "dropped" => 0 }]])
    expect(InvoiceOperation.pluck(:state)).to eq(["committed"])
    expect(Reservation.where(entry_id:).pluck(:invoice_id, :state)).to eq([[501, "committed"]])
  end

  # Holds a reservation operation at hold_at, runs other_writer on its own
  # connection until the server reports it blocked by the held operation,
  # then lets both finish. The held operation is always released before the
  # joins, so a failed wait check cannot leave it holding its locks while the
  # tables are truncated. Returns the held operation's outcome and
  # other_writer's.
  def race_held_reservation_against(held_request, hold_at:, &other_writer)
    reached = Queue.new
    release = Queue.new
    held_pid = Queue.new
    other_pid = Queue.new
    checkpoint = lambda do |step|
      next unless step == hold_at

      reached << true
      release.pop
    end
    held = on_own_reservation_connection(held_pid) { described_class.new(checkpoint:).call(held_request) }
    expect(reached.pop(timeout: wait_seconds)).to be(true)
    other = on_own_reservation_connection(other_pid, &other_writer)
    begin
      blocked = reservation_blocked_by?(other_pid.pop(timeout: wait_seconds), held_pid.pop(timeout: wait_seconds))
    ensure
      release << true
    end
    results = [held.join(wait_seconds)&.value, other.join(wait_seconds)&.value]
    expect(blocked).to be(true), "the other writer never waited on the held operation's lock"
    results
  end

  # The waiting update must see the reservation prepare committed, so an
  # employee cannot change an entry that is now locked.
  it "refuses an employee update that waited on a prepare of the same entry" do
    token = timekeeping_arrange.token_for(user)
    update = build_entry_command(:update, token:, entry_id:, body: { "duration" => 91.0 })
    seeded = Entry.find(entry_id)
    expect(seeded.duration).not_to be_nil
    expect(seeded.version).to eq(1)
    expect(AuditEvent.where(entry_id:).count).to eq(0)
    expect(OutboxSnapshot.where(id: entry_id).count).to eq(0)

    prepared, updated = race_held_reservation_against(
      race_request(:prepare, operation_id: SecureRandom.uuid, entry_ids: [entry_id]), hold_at: :rows_locked
    ) { Timekeeping::EntryWriter.new.call(update) }

    expect([prepared.status, updated.status]).to eq([200, 403])
    entry = Entry.find(entry_id)
    expect(entry.duration).to eq(seeded.duration)
    # Only the prepare's locked flip shows: the refused update adds no
    # version, audit row or snapshot.
    expect(entry.version).to eq(seeded.version + 1)
    expect(Reservation.where(entry_id:).pluck(:invoice_id, :state)).to eq([[501, "provisional"]])
    expect(AuditEvent.where(entry_id:).order(:id).pluck(:action, :after)).to eq([["prepare", { "locked" => true }]])
    expect(OutboxSnapshot.where(id: entry_id).order(:outbox_position).pluck(:version, :locked))
      .to eq([[seeded.version + 1, true]])
  end

  # A6 does not bind deletes (A10), so the waiting bulk delete still discards
  # the entry the prepare just reserved, and the reservation stays. This pins
  # that current behaviour; it does not endorse a discarded entry holding a
  # provisional reservation. The audit row and snapshot come from a read made
  # after the delete, so this proves the serialized stored outcome, not which
  # reservation flag the delete decision saw: the update example above is the
  # check for that.
  it "discards a reserved entry when an employee bulk delete waited on its prepare" do
    token = timekeeping_arrange.token_for(user)
    bulk_delete = build_entry_command(:bulk_delete, token:, body: { "entry_ids" => [entry_id] })
    seeded_version = Entry.find(entry_id).version
    expect(seeded_version).to eq(1)

    prepared, deleted = race_held_reservation_against(
      race_request(:prepare, operation_id: SecureRandom.uuid, entry_ids: [entry_id]), hold_at: :rows_locked
    ) { Timekeeping::EntryWriter.new.call(bulk_delete) }

    expect(prepared.status).to eq(200)
    expect(answer(deleted)).to eq([200, { "results" => [{ "entry_id" => entry_id, "result" => "deleted" }] }])
    entry = Entry.find(entry_id)
    expect(entry.discarded_at).not_to be_nil
    expect(entry.version).to eq(seeded_version + 2)
    expect(Reservation.where(entry_id:).pluck(:invoice_id, :state)).to eq([[501, "provisional"]])
    expect(AuditEvent.where(entry_id:).order(:id).pluck(:action)).to eq(%w[prepare bulk_delete])
    expect(AuditEvent.where(entry_id:, action: "prepare").pluck(:after)).to eq([{ "locked" => true }])
    snapshots = OutboxSnapshot.where(id: entry_id).order(:outbox_position).pluck(:version, :discarded_at, :locked)
    expect(snapshots.map { |version, discarded_at, locked| [version, !discarded_at.nil?, locked] })
      .to eq([[seeded_version + 1, false, true], [seeded_version + 2, true, true]])
  end

  # The waiting mark-billed must see that the successor took the entry, so it
  # never bills an entry its invoice no longer holds.
  it "bills nothing for an invoice whose retained entry a successor committed while mark-billed waited" do
    retained_entry = timekeeping_arrange.reserved_entry(company:, invoice_id: 501, disposition: "retained")
    successor_id = SecureRandom.uuid
    expect(described_class.new.call(race_request(:prepare, operation_id: successor_id, invoice_id: 502,
                                                           entry_ids: [retained_entry])).status).to eq(200)
    mark_billed = Timekeeping::ServiceCommands::Request.new(
      route: :mark_billed, company_id: company, actor_name: "invoice-boundary", target_id: 501,
      operation_id: SecureRandom.uuid, generation: timekeeping_arrange.current_generation
    )
    # The entry stays reserved from seeding through the handoff, so neither the
    # prepare nor the commit flips its locked flag: the baseline is the seeded
    # entry with no audit row or snapshot, and the race must leave it that way.
    baseline = Entry.find(retained_entry)
    expect([baseline.version, baseline.bill_status]).to eq([1, "unbilled"])
    expect(Reservation.where(entry_id: retained_entry).order(:invoice_id).pluck(:invoice_id, :state))
      .to eq([[501, "committed"], [502, "provisional"]])
    baseline_audit = AuditEvent.where(entry_id: retained_entry).order(:id).pluck(:action, :after)
    baseline_snapshots = OutboxSnapshot.where(id: retained_entry).order(:outbox_position).pluck(:version, :locked)
    expect([baseline_audit, baseline_snapshots]).to eq([[], []])

    committed, billed = race_held_reservation_against(
      race_request(:commit, operation_id: successor_id, invoice_id: 502), hold_at: :rows_locked
    ) { Timekeeping::ServiceCommands.new.call(mark_billed) }

    expect([answer(committed), answer(billed)])
      .to eq([[200, { "reserved" => 1, "released" => 0 }], [200, { "billed" => 0 }]])
    entry = Entry.find(retained_entry)
    expect([entry.version, entry.bill_status]).to eq([baseline.version, "unbilled"])
    expect(Reservation.where(entry_id: retained_entry).pluck(:invoice_id, :state)).to eq([[502, "committed"]])
    expect(AuditEvent.where(entry_id: retained_entry).order(:id).pluck(:action, :after)).to eq(baseline_audit)
    expect(OutboxSnapshot.where(id: retained_entry).order(:outbox_position).pluck(:version, :locked))
      .to eq(baseline_snapshots)
  end

  # The waiting prepare must see the entry as the abort left it (unlocked), so
  # reserving it again is a locked flip with its own version, audit and snapshot.
  it "records the relock when a prepare for another invoice waits on an abort of the same entry" do
    operation_id = SecureRandom.uuid
    expect(described_class.new.call(race_request(:prepare, operation_id:, entry_ids: [entry_id])).status).to eq(200)
    version_after_lock = Entry.find(entry_id).version

    aborted, prepared = race_reservations(
      race_request(:abort, operation_id:),
      race_request(:prepare, operation_id: SecureRandom.uuid, invoice_id: 502, entry_ids: [entry_id]),
      hold_at: :rows_locked
    )

    expect([aborted.first, prepared.first]).to eq([200, 200])
    expect(Entry.find(entry_id).version).to eq(version_after_lock + 2)
    expect(AuditEvent.where(entry_id:).order(:id).pluck(:action, :after))
      .to eq([["prepare", { "locked" => true }], ["abort", { "locked" => false }], ["prepare", { "locked" => true }]])
    expect(OutboxSnapshot.where(id: entry_id).order(:outbox_position).pluck(:locked)).to eq([true, false, true])
  end
end
