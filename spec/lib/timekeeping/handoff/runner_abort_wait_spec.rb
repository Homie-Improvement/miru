# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# The seed loads in a before(:all) of a shared context that RSpec includes only
# once per ancestry, and :seeded_without_transaction rolls nothing back. Every
# example below commits a cutover and a rollback, so each sits in its own
# context carrying the seed tags; tagging this describe would give them one seed.
RSpec.describe Timekeeping::Handoff::Runner do
  let(:abort_wait_calls) { [] }
  let(:abort_wait_clock) { Struct.new(:now).new(Time.utc(2026, 10, 27, 12)) }
  let(:abort_wait_store) { TimekeepingHandoffFakes::InMemoryTimekeepingStore.new(log: abort_wait_calls, tag: :timekeeping) }
  let(:abort_wait_relay_state) { { paused: false } }
  let(:abort_wait_relay) do
    state = abort_wait_relay_state
    TimekeepingHandoffOutboxRelay.new(store: abort_wait_store, log: abort_wait_calls, paused: -> { state[:paused] })
  end
  # A settle integration whose settled? answer the example switches.
  let(:abort_wait_settle) do
    Class.new do
      attr_accessor :settled

      def initialize = @settled = true
      def settle!(generation:) = nil
      def stop_applying! = nil
      def settled? = settled
    end.new
  end
  let(:abort_wait_owners) do
    built = TimekeepingHandoffFakes.owners(
      timekeeping: abort_wait_store,
      monolith_admission: TimekeepingHandoffFakes::RecordingAdmission.new(log: abort_wait_calls, tag: :monolith),
      settle: abort_wait_settle, log: abort_wait_calls
    )
    built.merge(timekeeping: built.fetch(:timekeeping).with(drain: abort_wait_relay))
  end
  let(:abort_wait_cutover_root) { Pathname(Dir.mktmpdir("handoff-abort-wait-cutover")) }
  let(:abort_wait_rollback_root) { Pathname(Dir.mktmpdir("handoff-abort-wait-rollback")) }

  # More polls than any example needs, so a wait that never ends fails the example instead of hanging the suite.
  def abort_wait_poll_cap = 10

  def abort_wait_row_state
    ownership = TimekeepingOwnership.current
    [ownership.generation, ownership.owner, ownership.handoff_step]
  end

  def abort_wait_admits = abort_wait_calls.select { |call| call[1] == :admit }

  def abort_wait_run(direction, **options)
    report_root = direction == :cutover ? abort_wait_cutover_root : abort_wait_rollback_root
    described_class.run(direction:, owners: abort_wait_owners, report_root:, clock: abort_wait_clock, **options)
  end

  # Records each sleep, fails once the poll cap is passed, and hands the poll number to on_poll.
  def abort_wait_sleeper(sleeps, &on_poll)
    cap = abort_wait_poll_cap
    lambda do |seconds|
      sleeps << seconds
      raise "the abort was still waiting after #{cap} polls" if sleeps.size > cap

      on_poll&.call(sleeps.size)
    end
  end

  def abort_wait_no_sleep(reason) = ->(_seconds) { raise reason }

  # A cutover, then an edit while Timekeeping owns the entries, which leaves one
  # snapshot in its outbox for the rollback to drain.
  def abort_wait_cutover_with_unsent_snapshot
    abort_wait_run(:cutover)
    expect(abort_wait_row_state).to eq([2, "timekeeping", nil])
    abort_wait_store.edit_entry!(abort_wait_store.rows.fetch("entries").first.fetch("id"))
    abort_wait_store.highest_outbox_position
  end

  context "abort waiting on a paused relay", :two_tenant_seed, :seeded_without_transaction do
    it "one abort call waits while the relay is paused and reopens writes once after the drain completes" do
      final_position = abort_wait_cutover_with_unsent_snapshot
      abort_wait_calls.clear
      abort_wait_relay_state[:paused] = true

      expect do
        abort_wait_run(:rollback, sleeper: abort_wait_no_sleep("a forward run must not wait"))
      end.to raise_error(described_class::Refused)
      expect(abort_wait_row_state).to eq([3, "timekeeping", "settle"])

      sleeps = []
      sleeper = abort_wait_sleeper(sleeps) { |poll| abort_wait_relay_state[:paused] = false if poll == 2 }

      # "abort waits while the relay is paused."
      # "Refusing the call and requiring another invocation changes the explicitly requested caller contract."
      expect { abort_wait_run(:rollback, abort: true, sleeper:) }.not_to raise_error

      expect(sleeps).to eq([described_class::ABORT_POLL_INTERVAL] * 2)
      expect(abort_wait_row_state).to eq([3, "timekeeping", nil])
      expect(abort_wait_relay.drained?(through: final_position)).to be(true)
      expect(abort_wait_admits).to eq([[:timekeeping, :admit, 3]])
      last_drain = abort_wait_calls.rindex { |call| call[0] == :drain }
      expect(abort_wait_calls.index([:timekeeping, :admit, 3])).to be > last_drain
    end
  end

  context "abort waiting on an unsettled integration", :two_tenant_seed, :seeded_without_transaction do
    it "one abort call waits for an unsettled Timekeeping integration and reopens Timekeeping once it settles" do
      abort_wait_run(:cutover)

      abort_wait_settle.settled = false
      expect { abort_wait_run(:rollback) }.to raise_error(described_class::Refused)
      expect(abort_wait_row_state).to eq([3, "timekeeping", "close_admission"])

      abort_wait_calls.clear
      sleeps = []
      sleeper = abort_wait_sleeper(sleeps) { abort_wait_settle.settled = true }

      # "Refusing the call and requiring another invocation changes the explicitly requested caller contract."
      expect { abort_wait_run(:rollback, abort: true, sleeper:) }.not_to raise_error

      expect(sleeps).to eq([described_class::ABORT_POLL_INTERVAL])
      expect(abort_wait_row_state).to eq([3, "timekeeping", nil])
      expect(abort_wait_admits).to eq([[:timekeeping, :admit, 3]])
    end
  end

  context "abort interrupted while the relay is paused", :two_tenant_seed, :seeded_without_transaction do
    it "an abort interrupted while waiting on a paused relay leaves the rollback fenced and a later abort admits exactly once" do
      final_position = abort_wait_cutover_with_unsent_snapshot
      abort_wait_calls.clear
      abort_wait_relay_state[:paused] = true
      no_wait = abort_wait_no_sleep("no wait expected")

      # A forward run keeps its single-attempt refusal and must never start waiting.
      expect { abort_wait_run(:rollback, sleeper: no_wait) }.to raise_error(described_class::Refused)
      fenced = abort_wait_row_state
      expect(fenced).to eq([3, "timekeeping", "settle"])

      # The operator interrupts the waiting abort on its third poll, while the relay is still paused: the
      # exception must leave before any row write or admit, or writes would reopen over an undrained outbox.
      operator_interrupt = Class.new(StandardError)
      sleeps = []
      sleeper = abort_wait_sleeper(sleeps) { |poll| raise operator_interrupt if poll == 3 }
      expect { abort_wait_run(:rollback, abort: true, sleeper:) }.to raise_error(operator_interrupt)
      expect(sleeps).to eq([described_class::ABORT_POLL_INTERVAL] * 3)
      expect(abort_wait_row_state).to eq(fenced)
      expect(abort_wait_admits).to be_empty
      expect(abort_wait_relay.drained?(through: final_position)).to be(false)

      # The interrupt released the handoff lock and left the handoff resumable, so a later abort completes
      # without waiting and reopens the outgoing owner exactly once.
      abort_wait_relay_state[:paused] = false
      abort_wait_run(:rollback, abort: true, sleeper: no_wait)
      expect(abort_wait_row_state).to eq([3, "timekeeping", nil])
      expect(abort_wait_admits).to eq([[:timekeeping, :admit, 3]])
      expect(abort_wait_relay.drained?(through: final_position)).to be(true)
    end
  end

  context "abort interrupted after settle while the relay is paused", :two_tenant_seed, :seeded_without_transaction do
    it "an abort that waits through settle and is interrupted while the relay is still paused records settle but admits nothing" do
      abort_wait_cutover_with_unsent_snapshot
      abort_wait_calls.clear
      abort_wait_settle.settled = false
      abort_wait_relay_state[:paused] = true
      expect do
        abort_wait_run(:rollback, sleeper: abort_wait_no_sleep("a forward run must not wait"))
      end.to raise_error(described_class::Refused)
      expect(abort_wait_row_state).to eq([3, "timekeeping", "close_admission"])

      # Settlement finishes during the first wait; the relay stays paused, so the abort moves on and waits
      # at freeze, where the operator interrupts it. Admitting here would reopen writes over unsent snapshots.
      operator_interrupt = Class.new(StandardError)
      sleeps = []
      sleeper = abort_wait_sleeper(sleeps) do |poll|
        raise operator_interrupt if poll == 2

        abort_wait_settle.settled = true
      end
      expect { abort_wait_run(:rollback, abort: true, sleeper:) }.to raise_error(operator_interrupt)
      expect(sleeps.size).to eq(2)
      expect(abort_wait_row_state).to eq([3, "timekeeping", "settle"])
      expect(abort_wait_admits).to be_empty

      abort_wait_relay_state[:paused] = false
      abort_wait_run(:rollback, abort: true, sleeper: abort_wait_no_sleep("no wait expected once the relay delivers"))
      expect(abort_wait_row_state).to eq([3, "timekeeping", nil])
      expect(abort_wait_admits).to eq([[:timekeeping, :admit, 3]])
    end
  end

  context "an abort waiting while another operator resumes", :two_tenant_seed, :seeded_without_transaction,
          committed_data: true do
    it "a resume started on another connection while an abort waits on a paused relay is refused by the handoff lock and the abort later admits once" do
      # Built here, on this thread, so the abort thread below reuses the same fakes.
      owners = abort_wait_owners
      rollback_root = abort_wait_rollback_root
      clock = abort_wait_clock
      abort_wait_cutover_with_unsent_snapshot

      abort_wait_calls.clear
      abort_wait_relay_state[:paused] = true
      expect { abort_wait_run(:rollback) }.to raise_error(described_class::Refused)
      fenced = abort_wait_row_state
      expect(fenced).to eq([3, "timekeeping", "settle"])

      waiting = Queue.new
      release = Queue.new
      sleeper = lambda do |_seconds|
        waiting << true
        release.pop
      end
      abort_error = nil
      abort_run = committed_data_thread do
        described_class.run(direction: :rollback, abort: true, owners:, report_root: rollback_root, clock:, sleeper:)
      rescue StandardError => error
        abort_error = error
      end

      begin
        expect(waiting.pop(timeout: 10)).to be(true)

        # "abort waits while the relay is paused." The abort holds the handoff lock for its whole wait,
        # so a resume from another session fails fast instead of interleaving with the abort's row writes.
        expect { abort_wait_run(:rollback) }
          .to raise_error(described_class::Refused, /Another Timekeeping handoff run holds the handoff lock/)
        expect(abort_wait_row_state).to eq(fenced)
        expect(abort_wait_admits).to be_empty
      ensure
        abort_wait_relay_state[:paused] = false
        release << true
        stop_committed_data_threads(abort_run, wait: 10)
      end

      expect(abort_error).to be_nil
      expect(abort_wait_row_state).to eq([3, "timekeeping", nil])
      expect(abort_wait_admits).to eq([[:timekeeping, :admit, 3]])
    end
  end
end
