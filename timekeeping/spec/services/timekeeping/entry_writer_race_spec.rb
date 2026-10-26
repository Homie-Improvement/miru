# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

# Two writers on two connections, with the first held at a named step of its
# transaction while the second runs, so each race meets at a known point
# instead of depending on thread timing.
RSpec.describe Timekeeping::EntryWriter, "under concurrent requests" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  let(:wait_seconds) { 10 }

  let(:company) { timekeeping_arrange.company }
  let(:project) { timekeeping_arrange.project(company:) }
  let(:owner) { timekeeping_arrange.user(company:, role: "owner") }
  let(:owner_token) { timekeeping_arrange.token_for(owner) }
  let(:entry_id) { timekeeping_arrange.entry(company:, user: owner, project:) }

  def command(route, **options)
    build_entry_command(route, token: owner_token, **options)
  end

  # Runs the block on a connection of its own, first pushing that
  # connection's server process id to backend_pids when one is given.
  def on_own_connection(backend_pids = nil, &block)
    Thread.new do
      ApplicationRecord.connection_pool.with_connection do |connection|
        backend_pids&.push(connection.select_value("SELECT pg_backend_pid()"))
        block.call
      end
    end
  end

  # Runs the first command until it reaches hold_at, then runs second (a
  # block) on another connection, and lets the first go on only once the
  # server reports the second connection blocked by the first one's locks.
  # Returns both results.
  def race(first_command, hold_at:, &second)
    reached = Queue.new
    release = Queue.new
    first_pid = Queue.new
    other_pid = Queue.new
    checkpoint = lambda do |step|
      next unless step == hold_at

      reached << true
      release.pop
    end
    first = on_own_connection(first_pid) { described_class.new(checkpoint:).call(first_command) }
    expect(reached.pop(timeout: wait_seconds)).to be(true)
    other = on_own_connection(other_pid, &second)
    blocked = blocked_by?(other_pid.pop(timeout: wait_seconds), first_pid.pop(timeout: wait_seconds))
    release << true
    results = [first.join(wait_seconds)&.value, other.join(wait_seconds)&.value]
    expect(blocked).to be(true), "the second request never waited on the first one's lock"
    results
  end

  def blocked_by?(waiting_pid, holding_pid)
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

  it "answers two identical PATCHes with one key and If-Match with the same 200 and raises the version once" do
    patch = command(:update, entry_id:, key: SecureRandom.uuid, body: { "note" => "Edited" }, if_match: "1")

    first, second = race(patch, hold_at: :receipt_checked) { described_class.new.call(patch) }

    expect([first.status, second.status]).to eq([200, 200])
    expect(second.body).to eq(first.body)
    expect(Entry.find(entry_id).version).to eq(2)
    expect(AuditEvent.count).to eq(1)
  end

  it "answers two identical DELETEs with one key with the same stored 200" do
    delete = command(:destroy, entry_id:, key: SecureRandom.uuid)

    first, second = race(delete, hold_at: :receipt_checked) { described_class.new.call(delete) }

    expect([first.status, second.status]).to eq([200, 200])
    expect(second.body).to eq(first.body)
    expect(Entry.find(entry_id).version).to eq(2)
  end

  it "makes a write to another entry, with another key, wait for the first write's outbox commit" do
    other_entry_id = timekeeping_arrange.entry(company:, user: owner, project:)
    first_patch = command(:update, entry_id:, body: { "note" => "First" })
    second_patch = command(:update, entry_id: other_entry_id, body: { "note" => "Second" })

    first, second = race(first_patch, hold_at: :outbox_written) { described_class.new.call(second_patch) }

    expect([first.status, second.status]).to eq([200, 200])
    expect(OutboxSnapshot.order(:outbox_position).pluck(:id)).to eq([entry_id, other_entry_id])
  end

  it "makes a fence wait until the write that read the admitted generation commits" do
    patch = command(:update, entry_id:, body: { "note" => "Edited" })

    first, = race(patch, hold_at: :generation_checked) { Timekeeping::Admission.fence! }

    expect(first.status).to eq(200)
    expect(Entry.find(entry_id).note).to eq("Edited")
    expect(Timekeeping::Admission.current.generation).to be_nil
  end

  it "refuses with stale_generation a write that reads the generation after a fence commits" do
    entry_id
    patch = command(:update, entry_id:, body: { "note" => "Edited" })
    reached = Queue.new
    release = Queue.new
    checkpoint = lambda do |step|
      next unless step == :receipt_checked

      reached << true
      release.pop
    end
    before = entry_write_counts

    writer = on_own_connection { described_class.new(checkpoint:).call(patch) }
    reached.pop(timeout: wait_seconds)
    Timekeeping::Admission.fence!
    release << true
    outcome = writer.join(wait_seconds).value

    expect([outcome.status, JSON.parse(outcome.body)]).to eq([409, { "reason" => "stale_generation" }])
    expect(entry_write_counts).to eq(before)
  end

  # Correctness only: the unique index and its backstop also give this result.
  it "answers two creates with one key and different bodies with one 201 and one 422" do
    key = SecureRandom.uuid
    body = { "project_id" => project, "work_date" => "2026-03-02", "duration" => 30.0, "note" => "One",
             "source" => "manual", "source_metadata" => {} }
    first_create = command(:create, key:, body:)
    second_create = command(:create, key:, body: body.merge("note" => "Two"))

    first, second = race(first_create, hold_at: :receipt_checked) { described_class.new.call(second_create) }

    expect([first.status, second.status]).to eq([201, 422])
    expect(Entry.count).to eq(1)
  end
end

# Generated by Descant: acceptance tests below.
RSpec.describe Timekeeping::EntryWriter, "fencing behind an admitted write" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # Fencing waits for writes already admitted, with a lock timeout of 60 s in production use
  # A fence that gives up must not count as a fence: the handoff then has to stop and resume or abort.
  it "a fence that times out behind an admitted write leaves the generation admitted and no lock timeout on the connection" do
    Timekeeping::Admission.ensure_initial!
    company = timekeeping_arrange.company
    owner = timekeeping_arrange.user(company:, role: "owner")
    token = timekeeping_arrange.token_for(owner)
    entry_id = timekeeping_arrange.entry(company:, user: owner, project: timekeeping_arrange.project(company:))
    patch = build_entry_command(:update, token:, entry_id:, generation: 1, body: { "note" => "Edited" })
    reached = Queue.new
    release = Queue.new
    checkpoint = lambda do |step|
      next unless step == :generation_checked

      reached << true
      release.pop
    end
    writer = Thread.new do
      ApplicationRecord.connection_pool.with_connection { described_class.new(checkpoint:).call(patch) }
    end

    begin
      expect(reached.pop(timeout: 10)).to be(true)
      expect { Timekeeping::Admission.fence!(lock_timeout: 0.2) }.to raise_error(ActiveRecord::LockWaitTimeout)
    ensure
      release << true
    end
    outcome = writer.join(10)&.value

    expect(outcome.status).to eq(200)
    expect(Timekeeping::Admission.current.generation).to eq(1)
    expect(ApplicationRecord.connection.select_value("SHOW lock_timeout")).to eq("0")
  end
end
