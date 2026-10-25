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

  def on_own_connection(&)
    Thread.new { ApplicationRecord.connection_pool.with_connection(&) }
  end

  # Runs the first command until it reaches hold_at, then runs second (a
  # block) on another connection, and lets the first go on only once a lock
  # wait shows the second is blocked behind it. Returns both results.
  def race(first_command, hold_at:, &second)
    reached = Queue.new
    release = Queue.new
    checkpoint = lambda do |step|
      next unless step == hold_at

      reached << true
      release.pop
    end
    first = on_own_connection { described_class.new(checkpoint:).call(first_command) }
    expect(reached.pop(timeout: wait_seconds)).to be(true)
    other = on_own_connection(&second)
    blocked = wait_for_lock_wait
    release << true
    results = [first.join(wait_seconds)&.value, other.join(wait_seconds)&.value]
    expect(blocked).to be(true), "the second request never waited on the first one's lock"
    results
  end

  def wait_for_lock_wait
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      return true if ApplicationRecord.connection.select_value("SELECT count(*) FROM pg_locks WHERE NOT granted").positive?

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

  it "makes an advance of an existing generation row wait until the write that read it commits" do
    patch = command(:update, entry_id:, body: { "note" => "Edited" })

    first, = race(patch, hold_at: :generation_checked) do
      Timekeeping::OwnershipGeneration.advance(company_id: company, generation: 2)
    end

    expect(first.status).to eq(200)
    expect(Timekeeping::OwnershipGeneration.find(company).generation).to eq(2)
  end

  # Correctness only: here the writer's own seed insert would also block a
  # concurrent advance, so this case cannot show the FOR SHARE read is needed.
  it "refuses with stale_generation a write for a company with no generation row when it advances first" do
    entry_id
    Timekeeping::OwnershipGeneration.where(company_id: company).delete_all
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
    Timekeeping::OwnershipGeneration.advance(company_id: company, generation: 2)
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
