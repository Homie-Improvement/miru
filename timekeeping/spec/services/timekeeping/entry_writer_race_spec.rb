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
  # while_blocked runs while the second connection is still waiting. The first
  # is always released, so a failure there cannot leave it holding its locks.
  # Returns both results.
  def race(first_command, hold_at:, while_blocked: -> { }, &second)
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
    begin
      blocked = blocked_by?(other_pid.pop(timeout: wait_seconds), first_pid.pop(timeout: wait_seconds))
      while_blocked.call
    ensure
      release << true
    end
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

    generation_while_waiting = nil

    first, = race(patch, hold_at: :generation_checked,
                         while_blocked: -> { generation_while_waiting = Timekeeping::Admission.current.generation }) do
      Timekeeping::Admission.fence!
    end

    expect(generation_while_waiting).to eq(1)
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
    # The outbox's NOT NULL generation column also stops a write past the
    # fence, but only by raising after the entry was written; the generation
    # check is what refuses it first. Kept as a value so a missing check fails
    # here, on an assertion, rather than through that error.
    outcome = begin
      writer.join(wait_seconds).value
    rescue ActiveRecord::ActiveRecordError => error
      error
    end

    expect(outcome).to be_a(Timekeeping::WriteOutcome),
                       "the write past the fence should be refused by the generation check " \
                       "(WriteSteps.generation_matches? in EntryWriter#write); it ended with #{outcome.inspect}"
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

  # Generated by Descant: acceptance tests below.
  # Fencing waits for writes already admitted, with a lock timeout of 60 s in production use
  # A fence that gives up must not count as a fence: the handoff then has to stop and resume or abort.
  it "a fence that times out behind an admitted write leaves the generation admitted and no lock timeout on the connection" do
    patch = command(:update, entry_id:, generation: 1, body: { "note" => "Edited" })
    reached = Queue.new
    release = Queue.new
    checkpoint = lambda do |step|
      next unless step == :generation_checked

      reached << true
      release.pop
    end
    writer = on_own_connection { described_class.new(checkpoint:).call(patch) }

    begin
      expect(reached.pop(timeout: wait_seconds)).to be(true)
      expect { Timekeeping::Admission.fence!(lock_timeout: 0.2) }.to raise_error(ActiveRecord::LockWaitTimeout)
    ensure
      release << true
    end
    outcome = writer.join(wait_seconds)&.value

    expect(outcome.status).to eq(200)
    expect(Timekeeping::Admission.current.generation).to eq(1)
    expect(ApplicationRecord.connection.select_value("SHOW lock_timeout")).to eq("0")
  end
end

# Generated by Descant: acceptance tests below.
RSpec.describe Timekeeping::EntryWriter, "agent create against a detach of the same agent" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  let(:wait_seconds) { 10 }
  let(:company) { timekeeping_arrange.company }
  let(:project) { timekeeping_arrange.project(company:) }
  let(:owner) { timekeeping_arrange.user(company:, role: "owner") }
  let(:agent) { timekeeping_arrange.agent(company:, user: owner) }

  def agent_create
    build_entry_command(:create, token: timekeeping_arrange.token_for(owner), body: {
                          "project_id" => project, "work_date" => "2026-03-02", "duration" => 60.0,
                          "note" => "Agent create", "source" => "automation", "source_metadata" => {},
                          "agent_id" => agent
                        })
  end

  def detach_request
    Timekeeping::ServiceCommands::Request.new(
      route: :detach_entries, company_id: company, actor_name: "agent-boundary", target_id: agent,
      operation_id: SecureRandom.uuid, generation: timekeeping_arrange.current_generation
    )
  end

  # Runs block on a connection of its own, first pushing that connection's
  # server process id to backend_pids.
  def on_own_agent_connection(backend_pids, &block)
    Thread.new do
      ApplicationRecord.connection_pool.with_connection do |connection|
        backend_pids.push(connection.select_value("SELECT pg_backend_pid()"))
        block.call
      end
    end
  end

  # Whether the database reports waiting_pid blocked by holding_pid within a
  # few seconds. A thread that has not finished may simply not have started,
  # so only the server's own lock graph shows a real wait.
  def agent_detach_blocked_by?(waiting_pid, holding_pid)
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

  # The parts of each WriteSteps.lock_key call the detach makes, in order, so
  # a test can name the lock the detach was in when the database saw it wait.
  # The lock itself is still taken by the product's own lock_key.
  def record_detach_lock_parts
    parts_seen = Queue.new
    allow(Timekeeping::WriteSteps).to receive(:lock_key).and_wrap_original do |lock_key, *parts|
      parts_seen << parts if Thread.current[:agent_detacher]
      lock_key.call(*parts)
    end
    parts_seen
  end

  # Whether waiting_pid waits for a transaction-scoped advisory lock (two
  # int4 keys, objsubid 2) that holding_pid holds granted. Read from pg_locks
  # only, so this check never takes the lock it looks for.
  def agent_waits_on_advisory_lock_held_by?(waiting_pid, holding_pid)
    ApplicationRecord.connection.select_value(ApplicationRecord.sanitize_sql_array([<<~SQL.squish, waiting_pid, holding_pid]))
      SELECT EXISTS (
        SELECT 1 FROM pg_locks waiting
        JOIN pg_locks holding ON holding.locktype = 'advisory' AND holding.granted
          AND holding.classid = waiting.classid AND holding.objid = waiting.objid AND holding.objsubid = 2
        WHERE waiting.locktype = 'advisory' AND NOT waiting.granted AND waiting.objsubid = 2
          AND waiting.pid = ? AND holding.pid = ?
      )
    SQL
  end

  # Runs the create until it reaches hold_at, then starts the detach on
  # another connection and lets the create go on after detach_wait seconds.
  # Returns the create's outcome, the detach's outcome, whether the detach
  # finished while the create was held, whether the database reported the
  # detach waiting on the create, and, when it did, the parts of the
  # advisory lock the detach was waiting in (nil when it waited on anything
  # else).
  def run_create_held_at(hold_at, detach_wait:)
    command = agent_create
    request = detach_request
    reached = Queue.new
    release = Queue.new
    creator_pids = Queue.new
    detacher_pids = Queue.new
    checkpoint = lambda do |step|
      next unless step == hold_at

      reached << true
      release.pop
    end
    detach_lock_parts = record_detach_lock_parts
    creator = on_own_agent_connection(creator_pids) { described_class.new(checkpoint:).call(command) }
    detacher = nil
    detach_finished_while_held = false
    detach_blocked = false
    waited_lock_parts = nil
    begin
      expect(reached.pop(timeout: wait_seconds)).to be(true)
      detacher = on_own_agent_connection(detacher_pids) do
        Thread.current[:agent_detacher] = true
        Timekeeping::ServiceCommands.new.call(request)
      end
      detach_finished_while_held = !detacher.join(detach_wait).nil?
      unless detach_finished_while_held
        detacher_pid = detacher_pids.pop(timeout: wait_seconds)
        creator_pid = creator_pids.pop(timeout: wait_seconds)
        detach_blocked = agent_detach_blocked_by?(detacher_pid, creator_pid)
        if agent_waits_on_advisory_lock_held_by?(detacher_pid, creator_pid)
          waited_lock_parts = Array.new(detach_lock_parts.size) { detach_lock_parts.pop }.last
        end
      end
    ensure
      release << true
    end
    [creator.join(wait_seconds)&.value, detacher&.join(wait_seconds)&.value, detach_finished_while_held,
     detach_blocked, waited_lock_parts]
  end

  it "makes a detach wait for a create that holds the agent lock, then detaches the committed entry" do
    created, detached, detach_finished_while_held, detach_blocked, waited_lock_parts =
      run_create_held_at(:generation_checked, detach_wait: 1)

    expect(detach_finished_while_held).to be(false),
                                          "the detach finished while the create held the agent lock " \
                                          "(ServiceCommands.lock_agent in EntryWriter#names_detached_agent?)"
    expect(detach_blocked).to be(true), "the detach never waited on the create holding the agent lock"
    expect(waited_lock_parts).to eq([company, "agent", agent]),
                                 "the detach should wait in its agent lock, WriteSteps.lock_key(company_id, \"agent\", " \
                                 "agent_id) in ServiceCommands#run, held by the create; it waited in lock_key " \
                                 "#{waited_lock_parts.inspect}"
    expect(created.status).to eq(201)
    expect([detached.status, JSON.parse(detached.body)]).to eq([200, { "detached" => 1 }])
    expect(Entry.sole.agent_id).to be_nil
  end

  # "A forwarded agent create racing an agent destroy never leaves an entry naming a deleted agent"
  # The create's facts are read before it is held, as they are for a create whose monolith caller timed
  # out and released its agent lock. Held before the agent lock, it lets the detach finish first, so the
  # create must then be refused.
  it "refuses a create held before the agent lock once a detach of the agent committed meanwhile" do
    created, detached, detach_finished_while_held = run_create_held_at(:receipt_checked, detach_wait: wait_seconds)

    expect(detach_finished_while_held).to be(true)
    expect([detached.status, JSON.parse(detached.body)]).to eq([200, { "detached" => 0 }])
    expect([created.status, JSON.parse(created.body)]).to eq([404, { "reason" => "not_found" }])
    expect(Entry.where(company_id: company, agent_id: agent)).to be_empty
    expect(Entry.count).to eq(0)
  end

  # A detach whose monolith deletion rolled back leaves the agent alive. The
  # monolith lists the agent in its facts again only once that deletion has
  # ended, so a write built afterwards reads its fence after the detach's
  # receipt and must be accepted, while a write built before the detach stays
  # refused.
  it "accepts a create built after a committed detach whose agent still exists, and still refuses one built before it" do
    built_before = agent_create
    detached = Timekeeping::ServiceCommands.new.call(detach_request)
    expect(detached.status).to eq(200)

    built_after = agent_create
    late = described_class.new.call(built_before)
    fresh = described_class.new.call(built_after)

    expect([late.status, JSON.parse(late.body)]).to eq([404, { "reason" => "not_found" }])
    expect(fresh.status).to eq(201)
    expect(Entry.sole.agent_id).to eq(agent)
  end
end
