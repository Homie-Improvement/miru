# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe Timekeeping::Handoff::Runner do
  context "abort waiting on a paused relay", :two_tenant_seed, :seeded_without_transaction do
    let(:abort_wait_calls) { [] }
    let(:abort_wait_clock) { Struct.new(:now).new(Time.utc(2026, 10, 27, 12)) }
    let(:abort_wait_store) { TimekeepingHandoffFakes::InMemoryTimekeepingStore.new(log: abort_wait_calls, tag: :timekeeping) }
    let(:abort_wait_monolith_admission) do
      TimekeepingHandoffFakes::RecordingAdmission.new(log: abort_wait_calls, tag: :monolith)
    end
    let(:abort_wait_monolith_store) { Timekeeping::Handoff::MonolithStore.new(connection: ActiveRecord::Base.connection) }
    let(:abort_wait_relay_paused) { { value: false } }
    let(:abort_wait_relay) do
      flag = abort_wait_relay_paused
      TimekeepingHandoffOutboxRelay.new(store: abort_wait_store, log: abort_wait_calls, paused: -> { flag[:value] })
    end
    let(:abort_wait_owners) do
      built = TimekeepingHandoffFakes.owners(timekeeping: abort_wait_store, monolith_admission: abort_wait_monolith_admission,
                                             monolith_store: abort_wait_monolith_store, log: abort_wait_calls)
      built.merge(timekeeping: built.fetch(:timekeeping).with(drain: abort_wait_relay))
    end

    it "one abort call waits while the relay is paused and reopens writes once after the drain completes" do
      cutover_root = Pathname(Dir.mktmpdir("handoff-abort-wait-cutover"))
      rollback_root = Pathname(Dir.mktmpdir("handoff-abort-wait-rollback"))
      described_class.run(direction: :cutover, owners: abort_wait_owners, report_root: cutover_root, clock: abort_wait_clock)
      expect(TimekeepingOwnership.current.owner).to eq("timekeeping")

      # An edit admitted in Timekeeping leaves a snapshot in its outbox that the rollback must drain.
      abort_wait_store.edit_entry!(abort_wait_store.rows.fetch("entries").first.fetch("id"))
      abort_wait_calls.clear
      abort_wait_relay_paused[:value] = true

      expect do
        described_class.run(direction: :rollback, owners: abort_wait_owners, report_root: rollback_root,
                            clock: abort_wait_clock, sleeper: ->(_seconds) { raise "a forward run must not wait" })
      end.to raise_error(Timekeeping::Handoff::Runner::Refused)
      expect(TimekeepingOwnership.current.handoff_step).to eq("settle")

      sleeps = []
      sleeper = lambda do |seconds|
        sleeps << seconds
        abort_wait_relay_paused[:value] = false if sleeps.size == 2
      end

      # "abort waits while the relay is paused."
      # "Refusing the call and requiring another invocation changes the explicitly requested caller contract."
      expect do
        described_class.run(direction: :rollback, abort: true, owners: abort_wait_owners, report_root: rollback_root,
                            clock: abort_wait_clock, sleeper:)
      end.not_to raise_error

      expect(sleeps).to eq([described_class::ABORT_POLL_INTERVAL] * 2)
      ownership = TimekeepingOwnership.current
      expect([ownership.generation, ownership.owner, ownership.handoff_step]).to eq([3, "timekeeping", nil])
      expect(abort_wait_relay.drained?(through: ownership.final_outbox_position || abort_wait_store.highest_outbox_position)).to be(true)

      admits = abort_wait_calls.select { |call| call[1] == :admit }
      expect(admits).to eq([[:timekeeping, :admit, 3]])
      last_drain = abort_wait_calls.rindex { |call| call[0] == :drain }
      expect(abort_wait_calls.index([:timekeeping, :admit, 3])).to be > last_drain
    end
  end
end

RSpec.describe Timekeeping::Handoff::Runner, :two_tenant_seed, :seeded_without_transaction do
  it "an abort interrupted while the relay is paused leaves the rollback fenced at settle and admits nobody" do
    calls = []
    clock = Struct.new(:now).new(Time.utc(2026, 10, 27, 12))
    store = TimekeepingHandoffFakes::InMemoryTimekeepingStore.new(log: calls, tag: :timekeeping)
    monolith_admission = TimekeepingHandoffFakes::RecordingAdmission.new(log: calls, tag: :monolith)
    monolith_store = Timekeeping::Handoff::MonolithStore.new(connection: ActiveRecord::Base.connection)
    relay_paused = false
    relay = TimekeepingHandoffOutboxRelay.new(store:, log: calls, paused: -> { relay_paused })
    built = TimekeepingHandoffFakes.owners(timekeeping: store, monolith_admission:, monolith_store:, log: calls)
    owners = built.merge(timekeeping: built.fetch(:timekeeping).with(drain: relay))
    cutover_root = Pathname(Dir.mktmpdir("handoff-abort-interrupt-cutover"))
    rollback_root = Pathname(Dir.mktmpdir("handoff-abort-interrupt-rollback"))

    described_class.run(direction: :cutover, owners:, report_root: cutover_root, clock:)
    store.edit_entry!(store.rows.fetch("entries").first.fetch("id"))
    final_position = store.highest_outbox_position

    relay_paused = true
    expect do
      described_class.run(direction: :rollback, owners:, report_root: rollback_root, clock:)
    end.to raise_error(Timekeeping::Handoff::Runner::Refused)

    calls.clear
    operator_interrupt = Class.new(StandardError)
    sleeps = 0
    # Stands in for the operator stopping the waiting task on its third poll; the relay never resumes.
    sleeper = lambda do |_seconds|
      sleeps += 1
      raise operator_interrupt if sleeps == 3
    end

    expect do
      described_class.run(direction: :rollback, abort: true, owners:, report_root: rollback_root, clock:, sleeper:)
    end.to raise_error(operator_interrupt)

    expect(sleeps).to eq(3)
    ownership = TimekeepingOwnership.current
    expect([ownership.generation, ownership.owner, ownership.handoff_step]).to eq([3, "timekeeping", "settle"])
    expect(calls.select { |call| call[1] == :admit }).to be_empty
    expect(relay.drained?(through: final_position)).to be(false)
  end
end

RSpec.describe Timekeeping::Handoff::Runner, :two_tenant_seed, :seeded_without_transaction do
  it "one abort call waits for an unsettled Timekeeping integration and reopens Timekeeping once it settles" do
    calls = []
    clock = Struct.new(:now).new(Time.utc(2026, 10, 27, 12))
    store = TimekeepingHandoffFakes::InMemoryTimekeepingStore.new(log: calls, tag: :timekeeping)
    monolith_admission = TimekeepingHandoffFakes::RecordingAdmission.new(log: calls, tag: :monolith)
    monolith_store = Timekeeping::Handoff::MonolithStore.new(connection: ActiveRecord::Base.connection)
    switchable_settle = Class.new do
      attr_accessor :settled

      def initialize = @settled = true
      def settle!(generation:) = nil
      def stop_applying! = nil
      def settled? = settled
    end.new
    owners = TimekeepingHandoffFakes.owners(timekeeping: store, monolith_admission:, monolith_store:,
                                            settle: switchable_settle, log: calls)
    cutover_root = Pathname(Dir.mktmpdir("handoff-abort-settle-cutover"))
    rollback_root = Pathname(Dir.mktmpdir("handoff-abort-settle-rollback"))

    described_class.run(direction: :cutover, owners:, report_root: cutover_root, clock:)

    switchable_settle.settled = false
    expect do
      described_class.run(direction: :rollback, owners:, report_root: rollback_root, clock:)
    end.to raise_error(Timekeeping::Handoff::Runner::Refused)
    ownership = TimekeepingOwnership.current
    expect([ownership.generation, ownership.owner, ownership.handoff_step]).to eq([3, "timekeeping", "close_admission"])

    calls.clear
    sleeps = []
    sleeper = lambda do |seconds|
      sleeps << seconds
      switchable_settle.settled = true
    end

    # "Refusing the call and requiring another invocation changes the explicitly requested caller contract."
    expect do
      described_class.run(direction: :rollback, abort: true, owners:, report_root: rollback_root, clock:, sleeper:)
    end.not_to raise_error

    expect(sleeps).to eq([described_class::ABORT_POLL_INTERVAL])
    ownership = TimekeepingOwnership.current
    expect([ownership.generation, ownership.owner, ownership.handoff_step]).to eq([3, "timekeeping", nil])
    expect(calls.select { |call| call[1] == :admit }).to eq([[:timekeeping, :admit, 3]])
  end
end

RSpec.describe Timekeeping::Handoff::Runner do
  context "abort interrupted while the relay is paused", :two_tenant_seed, :seeded_without_transaction do
    it "an abort interrupted while waiting on a paused relay leaves the rollback fenced and a later abort admits exactly once" do
      calls = []
      clock = Struct.new(:now).new(Time.utc(2026, 10, 27, 12))
      timekeeping_store = TimekeepingHandoffFakes::InMemoryTimekeepingStore.new(log: calls, tag: :timekeeping)
      monolith_admission = TimekeepingHandoffFakes::RecordingAdmission.new(log: calls, tag: :monolith)
      relay_paused = false
      relay = TimekeepingHandoffOutboxRelay.new(store: timekeeping_store, log: calls, paused: -> { relay_paused })
      built = TimekeepingHandoffFakes.owners(timekeeping: timekeeping_store, monolith_admission:, log: calls)
      owners = built.merge(timekeeping: built.fetch(:timekeeping).with(drain: relay))
      cutover_root = Pathname(Dir.mktmpdir("abort-wait-interrupt-cutover"))
      rollback_root = Pathname(Dir.mktmpdir("abort-wait-interrupt-rollback"))
      row_state = lambda do
        ownership = TimekeepingOwnership.current
        [ownership.generation, ownership.owner, ownership.handoff_step]
      end
      admits = -> { calls.select { |call| call[1] == :admit } }
      no_wait_expected = Class.new(StandardError)
      refusing_sleeper = ->(_seconds) { raise no_wait_expected }

      described_class.run(direction: :cutover, owners:, report_root: cutover_root, clock:)
      expect(row_state.call).to eq([2, "timekeeping", nil])
      # An edit after the cutover guarantees an unsent outbox row the paused relay holds back.
      timekeeping_store.edit_entry!(timekeeping_store.rows.fetch("entries").first.fetch("id"))

      calls.clear
      relay_paused = true
      # A forward run keeps its single-attempt refusal and must never start waiting.
      expect do
        described_class.run(direction: :rollback, owners:, report_root: rollback_root, clock:, sleeper: refusing_sleeper)
      end.to raise_error(described_class::Refused)
      fenced = row_state.call
      expect(fenced).to eq([3, "timekeeping", "settle"])

      # The operator interrupts the waiting abort: the exception must leave before any row write or admit,
      # or writes would reopen over an undrained outbox.
      operator_interrupt = Class.new(StandardError)
      sleeps = []
      interrupting_sleeper = lambda do |seconds|
        sleeps << seconds
        raise operator_interrupt
      end
      expect do
        described_class.run(direction: :rollback, abort: true, owners:, report_root: rollback_root, clock:,
                            sleeper: interrupting_sleeper)
      end.to raise_error(operator_interrupt)
      expect(sleeps).to eq([described_class::ABORT_POLL_INTERVAL])
      expect(row_state.call).to eq(fenced)
      expect(admits.call).to be_empty

      # The interrupt released the handoff lock and left the handoff resumable, so a later abort completes
      # without waiting and reopens the outgoing owner exactly once.
      relay_paused = false
      described_class.run(direction: :rollback, abort: true, owners:, report_root: rollback_root, clock:,
                          sleeper: refusing_sleeper)
      expect(row_state.call).to eq([3, "timekeeping", nil])
      expect(admits.call).to eq([[:timekeeping, :admit, 3]])
      expect(relay.drained?(through: timekeeping_store.highest_outbox_position)).to be(true)
    end
  end
end

RSpec.describe Timekeeping::Handoff::Runner do
  context "abort interrupted after settle while the relay is paused", :two_tenant_seed, :seeded_without_transaction do
    it "an abort that waits through settle and is interrupted while the relay is still paused records settle but admits nothing" do
      calls = []
      clock = Struct.new(:now).new(Time.utc(2026, 10, 27, 12))
      timekeeping_store = TimekeepingHandoffFakes::InMemoryTimekeepingStore.new(log: calls, tag: :timekeeping)
      monolith_admission = TimekeepingHandoffFakes::RecordingAdmission.new(log: calls, tag: :monolith)
      switchable_settle = Class.new do
        attr_accessor :settled

        def initialize = @settled = true
        def settle!(generation:) = nil
        def stop_applying! = nil
        def settled? = settled
      end.new
      relay_paused = false
      relay = TimekeepingHandoffOutboxRelay.new(store: timekeeping_store, log: calls, paused: -> { relay_paused })
      built = TimekeepingHandoffFakes.owners(timekeeping: timekeeping_store, monolith_admission:,
                                             settle: switchable_settle, log: calls)
      owners = built.merge(timekeeping: built.fetch(:timekeeping).with(drain: relay))
      cutover_root = Pathname(Dir.mktmpdir("abort-wait-settle-cutover"))
      rollback_root = Pathname(Dir.mktmpdir("abort-wait-settle-rollback"))
      row_state = lambda do
        ownership = TimekeepingOwnership.current
        [ownership.generation, ownership.owner, ownership.handoff_step]
      end
      admits = -> { calls.select { |call| call[1] == :admit } }

      described_class.run(direction: :cutover, owners:, report_root: cutover_root, clock:)
      expect(row_state.call).to eq([2, "timekeeping", nil])
      timekeeping_store.edit_entry!(timekeeping_store.rows.fetch("entries").first.fetch("id"))

      calls.clear
      switchable_settle.settled = false
      relay_paused = true
      expect do
        described_class.run(direction: :rollback, owners:, report_root: rollback_root, clock:,
                            sleeper: ->(_seconds) { raise "a forward run must not wait" })
      end.to raise_error(described_class::Refused)
      expect(row_state.call).to eq([3, "timekeeping", "close_admission"])

      # Settlement finishes during the first wait; the relay stays paused, so the abort moves on and waits
      # at freeze, where the operator interrupts it. Admitting here would reopen writes over unsent snapshots.
      operator_interrupt = Class.new(StandardError)
      sleeps = 0
      sleeper = lambda do |_seconds|
        sleeps += 1
        raise operator_interrupt if sleeps == 2

        switchable_settle.settled = true
      end
      expect do
        described_class.run(direction: :rollback, abort: true, owners:, report_root: rollback_root, clock:, sleeper:)
      end.to raise_error(operator_interrupt)
      expect(sleeps).to eq(2)
      expect(row_state.call).to eq([3, "timekeeping", "settle"])
      expect(admits.call).to be_empty

      relay_paused = false
      described_class.run(direction: :rollback, abort: true, owners:, report_root: rollback_root, clock:,
                          sleeper: ->(_seconds) { raise "no wait expected once the relay delivers" })
      expect(row_state.call).to eq([3, "timekeeping", nil])
      expect(admits.call).to eq([[:timekeeping, :admit, 3]])
    end
  end
end

RSpec.describe Timekeeping::Handoff::Runner do
  context "an abort waiting while another operator resumes", :two_tenant_seed, :seeded_without_transaction,
          committed_data: true do
    let(:lock_calls) { [] }
    let(:lock_clock) { Struct.new(:now).new(Time.utc(2026, 10, 27, 12)) }
    let(:lock_store) { TimekeepingHandoffFakes::InMemoryTimekeepingStore.new(log: lock_calls, tag: :timekeeping) }
    let(:lock_relay_paused) { [false] }
    let(:lock_monolith_admission) do
      log = lock_calls
      Class.new do
        define_method(:fence_admission) { log << [:monolith, :fence]; nil }
        define_method(:admit) { |generation:| log << [:monolith, :admit, generation]; nil }
        def enforces_fence? = true
      end.new
    end
    let(:lock_settle) do
      log = lock_calls
      Class.new do
        define_method(:settle!) { |generation:| log << [:settle, generation] }
        define_method(:stop_applying!) { log << [:stop_applying] }
        define_method(:settled?) { true }
      end.new
    end
    let(:lock_owners) do
      paused = lock_relay_paused
      relay = TimekeepingHandoffOutboxRelay.new(store: lock_store, log: lock_calls, paused: -> { paused.first })
      built = TimekeepingHandoffFakes.owners(
        timekeeping: lock_store, monolith_admission: lock_monolith_admission,
        monolith_store: Timekeeping::Handoff::MonolithStore.new(connection: ActiveRecord::Base.connection),
        settle: lock_settle, log: lock_calls
      )
      built.merge(timekeeping: built.fetch(:timekeeping).with(drain: relay))
    end

    def lock_row_state
      ownership = TimekeepingOwnership.current
      [ownership.generation, ownership.owner, ownership.handoff_step]
    end

    def lock_admits = lock_calls.select { |call| call[1] == :admit }

    it "a resume started on another connection while an abort waits on a paused relay is refused by the handoff lock and the abort later admits once" do
      cutover_root = Pathname(Dir.mktmpdir("abort-wait-lock-cutover"))
      rollback_root = Pathname(Dir.mktmpdir("abort-wait-lock-rollback"))
      owners = lock_owners
      described_class.run(direction: :cutover, owners:, report_root: cutover_root, clock: lock_clock)
      expect(lock_row_state).to eq([2, "timekeeping", nil])

      lock_calls.clear
      lock_relay_paused[0] = true
      expect do
        described_class.run(direction: :rollback, owners:, report_root: rollback_root, clock: lock_clock)
      end.to raise_error(Timekeeping::Handoff::Runner::Refused)
      fenced = lock_row_state
      expect(fenced).to eq([3, "timekeeping", "settle"])

      waiting = Queue.new
      release = Queue.new
      sleeper = lambda do |_seconds|
        waiting << true
        release.pop
      end
      abort_error = nil
      abort_run = committed_data_thread do
        described_class.run(direction: :rollback, abort: true, owners:, report_root: rollback_root,
                            clock: lock_clock, sleeper:)
      rescue StandardError => error
        abort_error = error
      end

      begin
        expect(waiting.pop(timeout: 10)).to be(true)

        # "abort waits while the relay is paused." The abort holds the handoff lock for its whole wait,
        # so a resume from another session fails fast instead of interleaving with the abort's row writes.
        expect do
          described_class.run(direction: :rollback, owners:, report_root: rollback_root, clock: lock_clock)
        end.to raise_error(Timekeeping::Handoff::Runner::Refused, /Another Timekeeping handoff run holds the handoff lock/)
        expect(lock_row_state).to eq(fenced)
        expect(lock_admits).to be_empty
      ensure
        lock_relay_paused[0] = false
        release << true
        stop_committed_data_threads(abort_run, wait: 10)
      end

      expect(abort_error).to be_nil
      expect(lock_row_state).to eq([3, "timekeeping", nil])
      expect(lock_admits).to eq([[:timekeeping, :admit, 3]])
    end
  end
end
