# frozen_string_literal: true

require "rails_helper"
require "json"
require "open3"
require "securerandom"
require "tmpdir"

RSpec.describe TimekeepingQueueLedger do
  describe ".write" do
    # "Record only the database, queue, job class, execution kind, ids and timestamps, never job arguments or credentials."
    it "a written ledger record holds only the database, queue, job class, kind, ids and timestamps and no job arguments or error text" do
      Dir.mktmpdir("queue-ledger-fields") do |dir|
        path = File.join(dir, "queue_ledger.json")
        record = described_class::Record.new(
          database: "monolith", queue: "billing_sync", job_class: "SyncStripeSubscriptionCompanyJob", kind: "failed",
          job_id: 7, active_job_id: "8f14e45f-ceea-467a-9575-0e2f1a7b6c01", execution_id: 3,
          created_at: "2026-01-01T00:00:00Z", finished_at: nil
        )

        described_class.write(path, records: [record], controls: [])

        written = JSON.parse(File.read(path)).fetch("records")
        expect(written.size).to eq(1)
        expect(written.first.keys).to match_array(
          %w[database queue job_class kind job_id active_job_id execution_id created_at finished_at]
        )
        expect(written.first.keys).not_to include("arguments", "error")
        expect(File.read(path)).not_to include("arguments")
        expect(Dir.children(dir)).to eq(["queue_ledger.json"])
      end
    end

    it "write appends to the ledger file in order across both databases and leaves no temp file after each write" do
      first = described_class::Record.new(
        database: "monolith", queue: "default", job_class: "UpdateInvoiceStatusToOverdueJob", kind: "completed",
        job_id: 1, active_job_id: "job-1", execution_id: nil,
        created_at: "2026-01-01T00:00:00.000000Z", finished_at: "2026-01-01T00:00:01.000000Z"
      )
      second = described_class::Record.new(
        database: "timekeeping", queue: "invoice_operations", job_class: "RelayJob", kind: "completed",
        job_id: 2, active_job_id: "job-2", execution_id: nil,
        created_at: "2026-01-01T00:00:02.000000Z", finished_at: "2026-01-01T00:00:03.000000Z"
      )

      Dir.mktmpdir("queue-ledger-append") do |dir|
        path = File.join(dir, "queue_ledger.json")

        # "It adds what it finds to tmp/timekeeping-integration/queue_ledger.json, outside the cleaned tables."
        # "Rewrite it atomically, with a temp file and a rename."
        described_class.write(path, records: [first], controls: [])
        expect(Dir.children(dir)).to eq(["queue_ledger.json"])
        described_class.write(path, records: [second], controls: [])
        expect(Dir.children(dir)).to eq(["queue_ledger.json"])

        stored = described_class.parse(File.read(path))[:records]
        expect(stored.map(&:active_job_id)).to eq(%w[job-1 job-2])
        expect(stored.map(&:job_id)).to eq([1, 2])
        expect(stored.map(&:database)).to eq(%w[monolith timekeeping])
      end
    end

    it "a control that ran stays recorded across a later write and still fails the verdict" do
      Dir.mktmpdir("queue-ledger-control") do |dir|
        path = File.join(dir, "queue_ledger.json")
        ran = TimekeepingQueueLedger::Control.new(
          queue: "default", job_class: "UpdateInvoiceStatusToOverdueJob", job_id: 5,
          active_job_id: SecureRandom.uuid, status: "ran"
        )
        clean_record = TimekeepingQueueLedger::Record.new(
          database: "monolith", queue: "invoice_operations", job_class: "RecoverInvoiceOperationIntentsJob",
          kind: "completed", job_id: 6, active_job_id: SecureRandom.uuid, execution_id: nil,
          created_at: "2026-01-01T00:00:00.000000Z", finished_at: "2026-01-01T00:00:01.000000Z"
        )

        TimekeepingQueueLedger.write(path, records: [], controls: [ran])
        TimekeepingQueueLedger.write(path, records: [clean_record], controls: [])

        stored = TimekeepingQueueLedger.parse(File.read(path))
        verdict = TimekeepingQueueLedger.verdict(records: stored[:records], controls: stored[:controls],
                                                 dedicated_queues: TimekeepingQueueLedger::DEDICATED_QUEUES)

        # "A control job that runs between resets fails the suite"
        expect(verdict.passed?).to be(false)
        expect(verdict.failures.join("\n")).to include(ran.active_job_id)
      end
    end

    # "An `after(:suite)` hook ... fails the run on any recorded execution or missing control."
    it "a control recorded missing stays missing when a later check finds it unrun" do
      Dir.mktmpdir("queue-ledger-sticky-missing") do |dir|
        path = File.join(dir, "queue_ledger.json")
        control = TimekeepingQueueLedger::Control.new(queue: "default", job_class: "UpdateInvoiceStatusToOverdueJob",
                                                      job_id: 1, active_job_id: SecureRandom.uuid, status: "missing")
        TimekeepingQueueLedger.write(path, records: [], controls: [control])
        TimekeepingQueueLedger.write(path, records: [], controls: [control.with(status: "unrun")])

        stored = TimekeepingQueueLedger.parse(File.read(path))
        expect(stored[:controls].map(&:status)).to eq(["missing"])
        verdict = TimekeepingQueueLedger.verdict(records: stored[:records], controls: stored[:controls],
                                                 dedicated_queues: TimekeepingQueueLedger::DEDICATED_QUEUES)
        expect(verdict.passed?).to be(false)
      end
    end
  end

  describe ".parse" do
    # "Any failure, or a ledger file that cannot be parsed, raises, and the run exits non-zero."
    it "parse raises UnreadableLedger for truncated text, for empty text and for JSON of the wrong shape" do
      unreadable = ["{\"records\": [", '{"records": [{"database": "monolith"', "", "[1, 2, 3]", "[]"]

      aggregate_failures do
        unreadable.each do |text|
          expect { described_class.parse(text) }
            .to raise_error(described_class::UnreadableLedger), "parse(#{text.inspect}) did not raise UnreadableLedger"
        end
      end
    end
  end

  describe ".verdict" do
    # "The verdict passes when the ledger is clean."
    it "verdict passes a clean ledger with two unrun controls and only dedicated executions" do
      controls = [
        described_class::Control.new(queue: "default", job_class: "UpdateInvoiceStatusToOverdueJob", job_id: 1,
                                     active_job_id: "control-default-1", status: "unrun"),
        described_class::Control.new(queue: "billing_sync", job_class: "SyncStripeSubscriptionCompanyJob", job_id: 2,
                                     active_job_id: "control-billing-2", status: "unrun")
      ]
      records = [
        described_class::Record.new(database: "monolith", queue: "invoice_operations", job_class: "RecoverInvoiceOperationIntentsJob",
                                    kind: "completed", job_id: 10, active_job_id: "relay-10", execution_id: nil,
                                    created_at: "2026-01-01T00:00:00Z", finished_at: "2026-01-01T00:00:01Z"),
        described_class::Record.new(database: "timekeeping", queue: "timekeeping_relay", job_class: "RelayJob",
                                    kind: "completed", job_id: 11, active_job_id: "relay-11", execution_id: nil,
                                    created_at: "2026-01-01T00:00:00Z", finished_at: "2026-01-01T00:00:01Z")
      ]

      verdict = described_class.verdict(records:, controls:, dedicated_queues: described_class::DEDICATED_QUEUES)

      expect(verdict.passed?).to be(true)
      expect(verdict.failures).to eq([])
    end

    # "A control job that runs, or any execution on a non-dedicated queue, fails the suite at teardown"
    it "verdict fails when the default control ran and names that control" do
      controls = [
        described_class::Control.new(queue: "default", job_class: "UpdateInvoiceStatusToOverdueJob", job_id: 1,
                                     active_job_id: "control-default-1", status: "ran"),
        described_class::Control.new(queue: "billing_sync", job_class: "SyncStripeSubscriptionCompanyJob", job_id: 2,
                                     active_job_id: "control-billing-2", status: "unrun")
      ]

      verdict = described_class.verdict(records: [], controls:, dedicated_queues: described_class::DEDICATED_QUEUES)

      expect(verdict.passed?).to be(false)
      expect(verdict.failures.size).to eq(1)
      expect(verdict.failures.first).to include("UpdateInvoiceStatusToOverdueJob")
    end

    it "verdict fails when a control observed unrun later shows up as a collected execution" do
      control_id = SecureRandom.uuid
      now = Time.utc(2026, 1, 1).iso8601
      controls = [
        described_class::Control.new(queue: "default", job_class: "UpdateInvoiceStatusToOverdueJob", job_id: 11,
                                     active_job_id: control_id, status: "unrun"),
        described_class::Control.new(queue: "billing_sync", job_class: "SyncStripeSubscriptionCompanyJob", job_id: 12,
                                     active_job_id: SecureRandom.uuid, status: "unrun")
      ]
      # The stop-time observation said unrun, but a later collect found the control finished.
      records = [
        described_class::Record.new(database: "monolith", queue: "default", job_class: "UpdateInvoiceStatusToOverdueJob",
                                    kind: "completed", job_id: 11, active_job_id: control_id, execution_id: nil,
                                    created_at: now, finished_at: now)
      ]

      # "A control job that runs between resets fails the suite"
      verdict = described_class.verdict(records:, controls:, dedicated_queues: described_class::DEDICATED_QUEUES)

      expect(verdict.passed?).to be(false)
      expect(verdict.failures.join("\n")).to include(control_id)
    end

    # "A missing control or an unparsable tmp/timekeeping-integration/queue_ledger.json fails the suite"
    it "verdict fails when the billing_sync control is missing" do
      controls = [
        described_class::Control.new(queue: "default", job_class: "UpdateInvoiceStatusToOverdueJob", job_id: 1,
                                     active_job_id: "control-default-1", status: "unrun"),
        described_class::Control.new(queue: "billing_sync", job_class: "SyncStripeSubscriptionCompanyJob", job_id: 2,
                                     active_job_id: "control-billing-2", status: "missing")
      ]

      verdict = described_class.verdict(records: [], controls:, dedicated_queues: described_class::DEDICATED_QUEUES)

      expect(verdict.passed?).to be(false)
      expect(verdict.failures.size).to eq(1)
      expect(verdict.failures.first).to include("SyncStripeSubscriptionCompanyJob")
    end

    it "verdict does not let another job on default stand in for a missing control" do
      controls = [
        described_class::Control.new(queue: "default", job_class: "UpdateInvoiceStatusToOverdueJob", job_id: 21,
                                     active_job_id: SecureRandom.uuid, status: "missing"),
        described_class::Control.new(queue: "billing_sync", job_class: "SyncStripeSubscriptionCompanyJob", job_id: 22,
                                     active_job_id: SecureRandom.uuid, status: "unrun")
      ]

      # "A job enqueued by other code never stands in for a control."
      verdict = described_class.verdict(records: [], controls:, dedicated_queues: described_class::DEDICATED_QUEUES)

      expect(verdict.passed?).to be(false)
    end

    # "Before the reset it checks that both still exist and have not run."
    it "verdict fails when a control was enqueued but never checked" do
      controls = [
        described_class::Control.new(queue: "default", job_class: "UpdateInvoiceStatusToOverdueJob", job_id: 1,
                                     active_job_id: "control-default-1", status: nil),
        described_class::Control.new(queue: "billing_sync", job_class: "SyncStripeSubscriptionCompanyJob", job_id: 2,
                                     active_job_id: "control-billing-2", status: "unrun")
      ]

      verdict = described_class.verdict(records: [], controls:, dedicated_queues: described_class::DEDICATED_QUEUES)

      expect(verdict.passed?).to be(false)
    end

    # "A job enqueued by other code never stands in for a control. An execution of other code's job on a non-dedicated queue still counts."
    it "verdict fails for a completed default job in the monolith that no control owns" do
      controls = [
        described_class::Control.new(queue: "default", job_class: "UpdateInvoiceStatusToOverdueJob", job_id: 1,
                                     active_job_id: "control-default-1", status: "unrun"),
        described_class::Control.new(queue: "billing_sync", job_class: "SyncStripeSubscriptionCompanyJob", job_id: 2,
                                     active_job_id: "control-billing-2", status: "unrun")
      ]
      records = [
        described_class::Record.new(database: "monolith", queue: "default", job_class: "UpdateInvoiceStatusToOverdueJob",
                                    kind: "completed", job_id: 99, active_job_id: "other-test-99", execution_id: nil,
                                    created_at: "2026-01-01T00:00:00Z", finished_at: "2026-01-01T00:00:01Z")
      ]

      verdict = described_class.verdict(records:, controls:, dedicated_queues: described_class::DEDICATED_QUEUES)

      expect(verdict.passed?).to be(false)
      expect(verdict.failures.size).to eq(1)
    end

    # "Dedicated queues are kept per database, as runtime_queues_spec.rb has them. The monolith allows `invoice_operations` and `timekeeping_relay`. Timekeeping allows only `timekeeping_relay`."
    it "verdict fails for invoice_operations in Timekeeping but passes the same record in the monolith" do
      controls = [
        described_class::Control.new(queue: "default", job_class: "UpdateInvoiceStatusToOverdueJob", job_id: 1,
                                     active_job_id: "control-default-1", status: "unrun"),
        described_class::Control.new(queue: "billing_sync", job_class: "SyncStripeSubscriptionCompanyJob", job_id: 2,
                                     active_job_id: "control-billing-2", status: "unrun")
      ]
      build = lambda do |database|
        described_class::Record.new(database:, queue: "invoice_operations", job_class: "RecoverInvoiceOperationIntentsJob",
                                    kind: "completed", job_id: 20, active_job_id: "invoice-op-20", execution_id: nil,
                                    created_at: "2026-01-01T00:00:00Z", finished_at: "2026-01-01T00:00:01Z")
      end
      dedicated = described_class::DEDICATED_QUEUES

      in_timekeeping = described_class.verdict(records: [build.call("timekeeping")], controls:, dedicated_queues: dedicated)
      in_monolith = described_class.verdict(records: [build.call("monolith")], controls:, dedicated_queues: dedicated)

      expect(in_timekeeping.passed?).to be(false)
      expect(in_monolith.passed?).to be(true)
      expect(dedicated.fetch("monolith")).to contain_exactly("invoice_operations", "timekeeping_relay")
      expect(dedicated.fetch("timekeeping")).to eq(["timekeeping_relay"])
    end

    # "Before every database reset, and once after the workers stop, it collects claimed, completed and failed Solid Queue executions on any queue other than the dedicated ones, in both databases."
    it "verdict fails for a claimed execution and for a failed execution on billing_sync" do
      controls = [
        described_class::Control.new(queue: "default", job_class: "UpdateInvoiceStatusToOverdueJob", job_id: 1,
                                     active_job_id: "control-default-1", status: "unrun"),
        described_class::Control.new(queue: "billing_sync", job_class: "SyncStripeSubscriptionCompanyJob", job_id: 2,
                                     active_job_id: "control-billing-2", status: "unrun")
      ]
      build = lambda do |kind, job_id|
        described_class::Record.new(database: "monolith", queue: "billing_sync", job_class: "SyncStripeSubscriptionCompanyJob",
                                    kind:, job_id:, active_job_id: "other-#{job_id}", execution_id: job_id + 100,
                                    created_at: "2026-01-01T00:00:00Z", finished_at: nil)
      end
      dedicated = described_class::DEDICATED_QUEUES

      claimed = described_class.verdict(records: [build.call("claimed", 30)], controls:, dedicated_queues: dedicated)
      failed = described_class.verdict(records: [build.call("failed", 31)], controls:, dedicated_queues: dedicated)

      expect(claimed.passed?).to be(false)
      expect(failed.passed?).to be(false)
    end
  end
end

RSpec.describe TimekeepingQueueLedger::Session do
  describe "#before_reset!" do
    # "A suite with no active ledger runs unchanged"
    # "As a backstop, it raises if a runtime is still live during a reset."
    it "does nothing while inactive, raises LiveRuntimeDuringReset at any reset while a runtime is live, and still judges the run at teardown" do
      untouchable = Class.new(BasicObject) do
        def method_missing(name, *) = ::Kernel.raise("collector used: #{name}")
        def respond_to_missing?(*) = true
      end.new
      used = []
      recording = Class.new(BasicObject) do
        define_method(:method_missing) do |name, *|
          used << name
          []
        end
        define_method(:respond_to_missing?) { |*| true }
      end.new

      Dir.mktmpdir("queue-ledger-before-reset") do |dir|
        inactive_path = File.join(dir, "inactive_ledger.json")
        inactive = described_class.new(path: inactive_path, collectors: untouchable, live: -> { raise "live check used" })

        expect { inactive.before_reset! }.not_to raise_error
        expect(File.exist?(inactive_path)).to be(false)

        live_path = File.join(dir, "live_ledger.json")
        live = described_class.new(path: live_path, collectors: recording, live: -> { true })
        live.activate!(env: { "TIMEKEEPING_DATABASE_URL" => "dbname=timekeeping_queue_ledger_live_test" })

        expect { live.before_reset! }.to raise_error(TimekeepingQueueLedger::LiveRuntimeDuringReset)
        expect(used).to eq([])
        expect(File.exist?(live_path)).to be(false)

        # "Before every database reset, and once after the workers stop, it collects ..."
        # The live check holds at every reset, and a refused reset leaves the session judging the run at teardown.
        stray = lambda do |job_class|
          TimekeepingQueueLedger::Record.new(
            database: "monolith", queue: "default", job_class:, kind: "completed", job_id: 9,
            active_job_id: SecureRandom.uuid, execution_id: nil, created_at: Time.current, finished_at: Time.current
          )
        end
        found = []
        runtime_live = false
        armed = described_class.new(path: File.join(dir, "armed_ledger.json"),
                                    collectors: { "monolith" => -> { found.dup } }, live: -> { runtime_live })
        armed.activate!(env: {})
        armed.before_reset!
        found << stray.call("QueueLedgerSecondResetJob")
        armed.before_reset!
        found.replace([stray.call("QueueLedgerTeardownJob")])

        runtime_live = true
        expect { armed.before_reset! }.to raise_error(TimekeepingQueueLedger::LiveRuntimeDuringReset)
        runtime_live = false

        expect { armed.finish! }.to raise_error(TimekeepingQueueLedger::RunFailed) { |error|
          expect(error.message).to include("QueueLedgerSecondResetJob")
          expect(error.message).to include("QueueLedgerTeardownJob")
        }
      end
    end
  end

  describe "#after_stop!" do
    # stop! runs from ensure blocks, so a ledger error there must not replace the boot or example error.
    it "after_stop! keeps a collector error for finish! instead of raising it" do
      Dir.mktmpdir("queue-ledger-after-stop") do |dir|
        session = described_class.new(path: File.join(dir, "queue_ledger.json"),
                                      collectors: { "monolith" => -> { raise TimekeepingQueueLedger::CollectError, "monolith unreachable" } },
                                      live: -> { false })
        session.activate!(env: {})

        expect(session.after_stop!).to be_nil
        expect { session.finish! }.to raise_error(TimekeepingQueueLedger::RunFailed, /monolith unreachable/)
      end
    end

    it "a boot error raised before stop! reaches the caller even when the ledger collector fails in stop!" do
      Dir.mktmpdir("queue-ledger-boot-error") do |dir|
        session = described_class.new(path: File.join(dir, "queue_ledger.json"),
                                      collectors: { "monolith" => -> { raise TimekeepingQueueLedger::CollectError, "monolith unreachable" } },
                                      live: -> { false })
        session.activate!(env: {})

        expect do
          raise IntegratedRuntime::BootError, "launcher exited"
        ensure
          session.after_stop!
        end.to raise_error(IntegratedRuntime::BootError, "launcher exited")
      end
    end
  end

  describe "#finish!" do
    it "an active session's finish! raises on an unparsable ledger file and passes on an empty valid one" do
      Dir.mktmpdir("queue-ledger-finish") do |dir|
        broken_path = File.join(dir, "broken.json")
        File.write(broken_path, "{not json")
        broken = TimekeepingQueueLedger::Session.new(path: broken_path, collectors: [], live: -> { false })
        broken.activate!(env: {})

        # "Any failure, or a ledger file that cannot be parsed, raises, and the run exits non-zero."
        expect { broken.finish! }.to raise_error(StandardError)

        clean_path = File.join(dir, "clean.json")
        File.write(clean_path, '{"records":[],"controls":[]}')
        clean = TimekeepingQueueLedger::Session.new(path: clean_path, collectors: [], live: -> { false })
        clean.activate!(env: {})

        expect { clean.finish! }.not_to raise_error
      end
    end

    # "A control job that runs, or any execution on a non-dedicated queue, fails the suite at teardown"
    it "a non-dedicated execution collected only at teardown fails finish! even after a clean reset was recorded" do
      Dir.mktmpdir("queue-ledger-teardown") do |dir|
        found = []
        record = TimekeepingQueueLedger::Record.new(
          database: "timekeeping", queue: "default", job_class: "StrayJob", kind: "completed", job_id: 7,
          active_job_id: SecureRandom.uuid, execution_id: nil, created_at: Time.current, finished_at: Time.current
        )
        session = described_class.new(path: File.join(dir, "queue_ledger.json"),
                                      collectors: { "monolith" => -> { [] }, "timekeeping" => -> { found.dup } },
                                      live: -> { false })
        session.activate!(env: ENV.to_h)
        session.collect!
        found << record

        expect { session.finish! }.to raise_error(StandardError, /StrayJob|default/)
      end
    end

    # "One after(:suite) hook stops any live runtime, collects once more and calls the pure `TimekeepingQueueLedger.verdict(records:, controls:, dedicated_queues:)`."
    it "finish! with a runtime whose stop! raises still collects, skips the live check and names the stop error and the failure" do
      collected = []
      stray = TimekeepingQueueLedger::Record.new(
        database: "monolith", queue: "default", job_class: "QueueLedgerStrayJob", kind: "completed", job_id: 3,
        active_job_id: SecureRandom.uuid, execution_id: nil, created_at: Time.current, finished_at: Time.current
      )
      failing_runtime = Object.new
      def failing_runtime.stop! = raise(IntegratedRuntime::BootError, "groups still alive after KILL")

      Dir.mktmpdir("queue-ledger-stop-failure") do |dir|
        session = described_class.new(path: File.join(dir, "queue_ledger.json"),
                                      collectors: { "monolith" => -> { collected << :monolith; [stray] } },
                                      live: -> { true })
        session.activate!(env: {})
        session.register_runtime(dir, runtime: failing_runtime)

        expect { session.finish! }.to raise_error(TimekeepingQueueLedger::RunFailed) { |error|
          expect(error.message).to include("groups still alive after KILL")
          expect(error.message).to include("QueueLedgerStrayJob")
          expect(error.message).not_to include("still live")
        }
        expect(collected).to eq([:monolith])
      end
    end
  end
end

RSpec.describe TimekeepingQueueLedger::TimekeepingCollector do
  # "Any failure, or a ledger file that cannot be parsed, raises, and the run exits non-zero."
  it "raises when TIMEKEEPING_DATABASE_URL is unset or unreachable, naming no URL or host" do
    expect { described_class.collect({}) }
      .to raise_error(TimekeepingQueueLedger::CollectError, /TIMEKEEPING_DATABASE_URL must be set/)

    unreachable = "postgres://queue_ledger_user@queue-ledger-unreachable.invalid:5432/queue_ledger_unreachable_test"
    expect { described_class.collect({ "TIMEKEEPING_DATABASE_URL" => unreachable }) }
      .to raise_error(TimekeepingQueueLedger::CollectError) { |error|
        expect(error.message).not_to include("queue-ledger-unreachable.invalid")
        expect(error.message).not_to include("queue_ledger_user")
        expect(error.cause).to be_nil
      }
  end
end

RSpec.describe TimekeepingDatabaseReset do
  # "Every reset path, including the seeded committed reset, collects executions before it deletes"
  # The name guard must still refuse an unsafe database before any collect or connection.
  it "reset! refuses a non-test database before it runs the collect hook" do
    calls = []

    expect do
      described_class.reset!("legacy", env: { described_class::DATABASE_URL_KEY => "dbname=timekeeping_production" },
                                       before_truncate: -> { calls << :collect })
    end.to raise_error(TestDatabaseGuard::NotATestDatabase)
    expect(calls).to eq([])
  end

  it "the Timekeeping database reset calls before_truncate once before it connects to a test database" do
    steps = []
    allow(PG).to receive(:connect) do
      steps << :connect
      raise PG::ConnectionBad, 'database "queue_ledger_never_created_test" does not exist'
    end

    # "Every reset path, including the seeded committed reset, collects executions before it deletes"
    result = described_class.reset!(
      "legacy",
      env: { described_class::DATABASE_URL_KEY => "dbname=queue_ledger_never_created_test" },
      before_truncate: -> { steps << :collect }
    )

    expect(result).to be_nil
    expect(steps).to eq(%i[collect connect])
  end
end

RSpec.describe TestDatabaseCleanup do
  # "Every reset path, including the seeded committed reset, collects executions before it deletes"
  it "the seeded committed reset collects before it deletes" do
    steps = []
    allow(described_class).to receive(:before_reset!) { steps << :collect }
    allow(DatabaseCleaner).to receive(:clean_with) { steps << :delete }
    allow(Timekeeping::SeedDispositionRecorder).to receive(:load_fresh_seed!) { steps << :seed }
    allow(TimekeepingOwnership).to receive(:ensure_initial!)
    allow(TimekeepingDatabaseReset).to receive(:reset!) { steps << :timekeeping_reset }

    described_class.reset_seeded_committed!(as_of: Date.new(2026, 1, 1), state: nil, env: {})

    expect(steps.first).to eq(:collect)
    expect(steps.index(:collect)).to be < steps.index(:delete)
    expect(steps).to include(:delete, :seed, :timekeeping_reset)
  end

  it "delete_all_committed! and the committed_data reset collect before they delete" do
    steps = []
    allow(described_class).to receive(:before_reset!) { steps << :collect }
    allow(DatabaseCleaner).to receive(:clean_with) { steps << :delete }
    allow(TimekeepingOwnership).to receive(:ensure_initial!)

    # "Every reset path, including the seeded committed reset, collects executions before it deletes"
    described_class.delete_all_committed!
    expect(steps).to eq(%i[collect delete])

    steps.clear
    CommittedDataMode.reset_database
    expect(steps).to eq(%i[collect delete])
  end

  # "Every reset path, including the seeded committed reset, collects executions before it deletes"
  it "the without_transaction and two_tenant_seed hooks collect before each of their truncates" do
    steps = []
    allow(described_class).to receive(:before_reset!) { steps << :collect }
    allow(DatabaseCleaner).to receive(:clean_with) { steps << :delete }
    allow(TimekeepingOwnership).to receive(:ensure_initial!)
    allow(Timekeeping::SeedDispositionRecorder).to receive(:load_fresh_seed!)
    allow(described_class).to receive(:delete_operation_ledger_rows!)

    inner = RSpec::Core::ExampleGroup.describe("queue ledger reset hooks", :without_transaction, :two_tenant_seed) do
      it("runs between the resets") { steps << :example }
    end
    passed = inner.run(RSpec::Core::NullReporter)
    RSpec.world.example_groups.delete(inner)

    expect(passed).to be(true)
    # before(:all) seed truncate, without_transaction before and after truncates, after(:all) truncate.
    expect(steps).to eq(%i[collect delete collect delete example collect delete collect delete])
  end
end

# Every example here that starts a child `bundle exec rspec` runs outside a transaction, because a parent
# transaction can hold locks the child's database cleaner waits on. Each child gets its own ledger path, because
# a child's suite start deletes whatever ledger file it inherits.
RSpec.describe "Timekeeping queue ledger probes", :without_transaction do
  let(:queue_ledger_probe) { Rails.root.join("spec/fixtures/timekeeping_harness/queue_ledger_probe.rb").to_s }

  before do |example|
    next unless example.metadata[:live_probe]

    skip "set TIMEKEEPING_LIVE=1 to run the queue ledger probes" unless ENV["TIMEKEEPING_LIVE"] == "1"
  end

  def run_queue_ledger_probe(mode, ledger_path)
    Open3.capture3({ "QUEUE_LEDGER_PROBE" => mode, TimekeepingQueueLedger::PATH_KEY => ledger_path },
                   "bundle", "exec", "rspec", queue_ledger_probe, chdir: Rails.root.to_s)
  end

  it "keeps the queue ledger probe out of a normal suite run" do
    probe = Pathname.new(queue_ledger_probe)

    expect(probe).to exist
    expect(probe.basename.to_s).not_to end_with("_spec.rb")
  end

  it "a clean probe run deletes a stale ledger file at suite start, so a record from an earlier run neither survives nor fails it", :live_probe do
    Dir.mktmpdir("queue-ledger-suite-start") do |dir|
      ledger_path = File.join(dir, "queue_ledger.json")
      stale_active_job_id = "stale-#{SecureRandom.uuid}"
      stale_record = {
        "database" => "monolith", "queue" => "default", "job_class" => "UpdateInvoiceStatusToOverdueJob",
        "kind" => "completed", "job_id" => 1, "active_job_id" => stale_active_job_id, "execution_id" => nil,
        "created_at" => "2026-01-01T00:00:00Z", "finished_at" => "2026-01-01T00:00:01Z"
      }
      File.write(ledger_path, JSON.generate({ "records" => [stale_record], "controls" => [] }))

      stdout, stderr, status = run_queue_ledger_probe("clean", ledger_path)
      output = "#{stdout}\n#{stderr}"

      # "Delete the ledger file at suite start."
      expect(status).to be_success, output
      expect(output.include?(stale_active_job_id)).to be(false)
      expect(File.exist?(ledger_path) && File.read(ledger_path).include?(stale_active_job_id)).to be(false)
    end
  end

  it "a probe that marks its default control finished between resets exits non-zero naming the control", :live_probe do
    Dir.mktmpdir("queue-ledger-probe") do |dir|
      stdout, stderr, status = run_queue_ledger_probe("control_ran", File.join(dir, "queue_ledger.json"))
      output = "#{stdout}\n#{stderr}"

      # "A probe that marks its `default` control finished between resets exits non-zero."
      expect(status).not_to be_success, output
      expect(output).to match(/control/i)
      expect(output).to include("UpdateInvoiceStatusToOverdueJob")
    end
  end

  it "a probe with a completed non-dedicated job exits non-zero and records it in its own ledger file", :live_probe do
    Dir.mktmpdir("queue-ledger-probe") do |dir|
      ledger_path = File.join(dir, "queue_ledger.json")
      stdout, stderr, status = run_queue_ledger_probe("non_dedicated", ledger_path)
      output = "#{stdout}\n#{stderr}"

      # "A completed job on any non-dedicated queue fails it, in either database"
      expect(status).not_to be_success, output
      expect(File.exist?(ledger_path)).to be(true)
      records = JSON.parse(File.read(ledger_path)).fetch("records")
      expect(records.any? { |record| record["queue"] == "default" && record["database"] == "monolith" }).to be(true)
    end
  end

  it "a clean queue ledger probe exits zero", :live_probe do
    Dir.mktmpdir("queue-ledger-probe") do |dir|
      stdout, stderr, status = run_queue_ledger_probe("clean", File.join(dir, "queue_ledger.json"))
      output = "#{stdout}\n#{stderr}"

      # "A clean probe exits zero."
      expect(status).to be_success, output
      expect(output).to include("0 failures")
    end
  end

  # "Every probe subprocess sets it to its own temporary file, so a probe never touches the parent run's ledger."
  it "a clean probe run leaves the parent's inherited ledger file byte for byte unchanged", :live_probe do
    Dir.mktmpdir("queue-ledger-parent") do |dir|
      parent_path = File.join(dir, "parent_ledger.json")
      child_path = File.join(dir, "child_ledger.json")
      violation = JSON.generate(
        "records" => [{ "database" => "monolith", "queue" => "default", "job_class" => "StrayJob",
                        "kind" => "completed", "job_id" => 1, "active_job_id" => "parent-violation",
                        "execution_id" => nil, "created_at" => "2026-01-01T00:00:00Z",
                        "finished_at" => "2026-01-01T00:00:01Z" }],
        "controls" => []
      )
      File.write(parent_path, violation)
      previous = ENV.fetch(TimekeepingQueueLedger::PATH_KEY, nil)
      begin
        ENV[TimekeepingQueueLedger::PATH_KEY] = parent_path
        stdout, stderr, status = run_queue_ledger_probe("clean", child_path)
      ensure
        ENV[TimekeepingQueueLedger::PATH_KEY] = previous
      end

      expect(status).to be_success, "#{stdout}\n#{stderr}"
      expect(File.binread(parent_path)).to eq(violation.b)
      expect(File.exist?(child_path)).to be(true)
    end
  end

  # Examples that finish, claim and fail default-queue jobs on purpose run in their own rspec process with a
  # private ledger path, so an active suite ledger here never records their rows as a stray worker's executions.
  it "Solid Queue row examples pass in their own run, which never touches this run's ledger" do
    probe = Rails.root.join("spec/fixtures/timekeeping_harness/queue_ledger_rows_probe.rb")
    expect(probe.basename.to_s).not_to end_with("_spec.rb")

    Dir.mktmpdir("queue-ledger-rows") do |dir|
      stdout, stderr, status = Open3.capture3(
        { TimekeepingQueueLedger::PATH_KEY => File.join(dir, "rows_ledger.json") },
        "bundle", "exec", "rspec", probe.to_s, chdir: Rails.root.to_s
      )

      expect(status).to be_success, "#{stdout}\n#{stderr}"
      expect(stdout).to include("7 examples, 0 failures")
    end
  end
end
