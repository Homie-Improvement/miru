# frozen_string_literal: true

require "rails_helper"
require "json"
require "open3"
require "securerandom"
require "tmpdir"

RSpec.describe "Timekeeping queue ledger file contents" do
  # "Record only the database, queue, job class, execution kind, ids and timestamps, never job arguments or credentials."
  it "a written ledger record holds only the database, queue, job class, kind, ids and timestamps and no job arguments or error text" do
    Dir.mktmpdir("queue-ledger-fields") do |dir|
      path = File.join(dir, "queue_ledger.json")
      record = TimekeepingQueueLedger::Record.new(
        database: "monolith", queue: "billing_sync", job_class: "SyncStripeSubscriptionCompanyJob", kind: "failed",
        job_id: 7, active_job_id: "8f14e45f-ceea-467a-9575-0e2f1a7b6c01", execution_id: 3,
        created_at: "2026-01-01T00:00:00Z", finished_at: nil
      )

      TimekeepingQueueLedger.write(path, records: [record], controls: [])

      written = JSON.parse(File.read(path))
      allowed = %w[database queue job_class kind job_id active_job_id execution_id created_at finished_at]
      expect(written.fetch("records").size).to eq(1)
      expect(written.fetch("records").first.keys - allowed).to eq([])
      expect(File.read(path)).not_to include("arguments")
      expect(Dir.children(dir)).to eq(["queue_ledger.json"])
    end
  end
end


RSpec.describe "Timekeeping queue ledger parsing" do
  # "Any failure, or a ledger file that cannot be parsed, raises, and the run exits non-zero."
  it "parsing a ledger file that is not valid JSON raises UnreadableLedger" do
    expect { TimekeepingQueueLedger.parse("{\"records\": [") }.to raise_error(TimekeepingQueueLedger::UnreadableLedger)
    expect { TimekeepingQueueLedger.parse("[1, 2, 3]") }.to raise_error(TimekeepingQueueLedger::UnreadableLedger)
  end
end


RSpec.describe "Timekeeping queue ledger reset guard" do
  # The collect step runs only after the database name guard, so a non-test database is refused before anything else.
  it "a Timekeeping reset of a database whose name does not end in _test refuses before the collect step runs" do
    collected = []

    expect do
      TimekeepingDatabaseReset.reset!("legacy", env: { "TIMEKEEPING_DATABASE_URL" => "dbname=timekeeping_production" },
                                                before_truncate: -> { collected << :collect })
    end.to raise_error(TestDatabaseGuard::NotATestDatabase)
    expect(collected).to eq([])
  end
end


RSpec.describe TimekeepingQueueLedger do
  it "write keeps the records an earlier write stored and leaves no temp file beside the ledger" do
    Dir.mktmpdir("queue-ledger-append") do |dir|
      path = File.join(dir, "queue_ledger.json")
      first = TimekeepingQueueLedger::Record.new(
        database: "monolith", queue: "default", job_class: "UpdateInvoiceStatusToOverdueJob", kind: "completed",
        job_id: 11, active_job_id: "first-#{SecureRandom.uuid}", execution_id: nil,
        created_at: "2026-01-01T00:00:00.000000Z", finished_at: "2026-01-01T00:00:01.000000Z"
      )
      second = TimekeepingQueueLedger::Record.new(
        database: "timekeeping", queue: "invoice_operations", job_class: "RelayJob", kind: "completed",
        job_id: 12, active_job_id: "second-#{SecureRandom.uuid}", execution_id: nil,
        created_at: "2026-01-01T00:00:02.000000Z", finished_at: "2026-01-01T00:00:03.000000Z"
      )

      TimekeepingQueueLedger.write(path, records: [first], controls: [])
      TimekeepingQueueLedger.write(path, records: [second], controls: [])

      # "It adds what it finds to tmp/timekeeping-integration/queue_ledger.json, outside the cleaned tables."
      stored = TimekeepingQueueLedger.parse(File.read(path))
      expect(stored[:records].map(&:active_job_id)).to contain_exactly(first.active_job_id, second.active_job_id)
      # "Rewrite it atomically, with a temp file and a rename."
      expect(Dir.children(dir)).to eq(["queue_ledger.json"])
    end
  end
end


RSpec.describe TimekeepingQueueLedger do
  it "a stored ledger record holds only database, queue, job class, kind, ids and timestamps" do
    Dir.mktmpdir("queue-ledger-fields") do |dir|
      path = File.join(dir, "queue_ledger.json")
      record = TimekeepingQueueLedger::Record.new(
        database: "monolith", queue: "billing_sync", job_class: "SyncStripeSubscriptionCompanyJob", kind: "failed",
        job_id: 7, active_job_id: SecureRandom.uuid, execution_id: 3,
        created_at: "2026-01-01T00:00:00.000000Z", finished_at: nil
      )

      TimekeepingQueueLedger.write(path, records: [record], controls: [])

      # "Record only the database, queue, job class, execution kind, ids and timestamps, never job arguments or credentials."
      stored = JSON.parse(File.read(path)).fetch("records")
      expect(stored.size).to eq(1)
      expect(stored.first.keys).to match_array(
        %w[database queue job_class kind job_id active_job_id execution_id created_at finished_at]
      )
      expect(File.read(path)).not_to include("arguments")
    end
  end
end


RSpec.describe TimekeepingQueueLedger do
  it "parse raises UnreadableLedger for a ledger file that is not valid JSON" do
    # "Any failure, or a ledger file that cannot be parsed, raises, and the run exits non-zero."
    expect { TimekeepingQueueLedger.parse("{\"records\": [") }.to raise_error(TimekeepingQueueLedger::UnreadableLedger)
  end
end


RSpec.describe TimekeepingQueueLedger do
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
end


RSpec.describe "Timekeeping queue ledger file at suite start" do
  it "a clean probe run deletes a stale ledger file at suite start, so a record from an earlier run neither survives nor fails it" do
    skip "set TIMEKEEPING_LIVE=1 to run the queue ledger probes" unless ENV["TIMEKEEPING_LIVE"] == "1"

    Dir.mktmpdir("queue-ledger-suite-start") do |dir|
      ledger_path = File.join(dir, "queue_ledger.json")
      stale_active_job_id = "stale-#{SecureRandom.uuid}"
      stale_record = {
        "database" => "monolith", "queue" => "default", "job_class" => "UpdateInvoiceStatusToOverdueJob",
        "kind" => "completed", "job_id" => 1, "active_job_id" => stale_active_job_id, "execution_id" => nil,
        "created_at" => "2026-01-01T00:00:00Z", "finished_at" => "2026-01-01T00:00:01Z"
      }
      File.write(ledger_path, JSON.generate({ "records" => [stale_record], "controls" => [] }))

      probe = Rails.root.join("spec/fixtures/timekeeping_harness/queue_ledger_probe.rb").to_s
      stdout, stderr, status = Open3.capture3({ "QUEUE_LEDGER_PROBE" => "clean", "TIMEKEEPING_QUEUE_LEDGER_PATH" => ledger_path },
                                              "bundle", "exec", "rspec", probe, chdir: Rails.root.to_s)
      output = "#{stdout}\n#{stderr}"

      # "Delete the ledger file at suite start."
      expect(status).to be_success, output
      expect(output.include?(stale_active_job_id)).to be(false)
      expect(File.exist?(ledger_path) && File.read(ledger_path).include?(stale_active_job_id)).to be(false)
    end
  end
end


RSpec.describe TimekeepingQueueLedger do
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
end


RSpec.describe TimekeepingQueueLedger do
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
end


RSpec.describe TimekeepingQueueLedger do
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
end


RSpec.describe TimekeepingQueueLedger do
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
end


RSpec.describe TimekeepingQueueLedger do
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
end


RSpec.describe TimekeepingQueueLedger do
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
end


RSpec.describe TimekeepingQueueLedger do
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


RSpec.describe TimekeepingQueueLedger do
  # "Any failure, or a ledger file that cannot be parsed, raises, and the run exits non-zero."
  it "parse raises UnreadableLedger for text that is not JSON and for JSON of the wrong shape" do
    expect { described_class.parse("{\"records\": [") }.to raise_error(described_class::UnreadableLedger)
    expect { described_class.parse("") }.to raise_error(described_class::UnreadableLedger)
    expect { described_class.parse("[1, 2, 3]") }.to raise_error(described_class::UnreadableLedger)
  end
end


RSpec.describe TimekeepingQueueLedger do
  # "Rewrite it atomically, with a temp file and a rename."
  it "write appends to the ledger file, keeps earlier records once each and leaves no temp file" do
    build = lambda do |job_id|
      described_class::Record.new(database: "monolith", queue: "default", job_class: "UpdateInvoiceStatusToOverdueJob",
                                  kind: "completed", job_id:, active_job_id: "job-#{job_id}", execution_id: nil,
                                  created_at: "2026-01-01T00:00:00Z", finished_at: "2026-01-01T00:00:01Z")
    end

    Dir.mktmpdir("queue-ledger-write") do |dir|
      path = File.join(dir, "queue_ledger.json")
      described_class.write(path, records: [build.call(1)], controls: [])
      described_class.write(path, records: [build.call(2)], controls: [])

      parsed = described_class.parse(File.read(path))
      expect(parsed[:records].map(&:active_job_id)).to eq(%w[job-1 job-2])
      expect(Dir.children(dir)).to eq(["queue_ledger.json"])
    end
  end
end


RSpec.describe TimekeepingQueueLedger do
  # "Record only the database, queue, job class, execution kind, ids and timestamps, never job arguments or credentials."
  it "the written ledger file holds no job arguments or error text" do
    record = described_class::Record.new(database: "monolith", queue: "billing_sync", job_class: "SyncStripeSubscriptionCompanyJob",
                                         kind: "failed", job_id: 7, active_job_id: "job-7", execution_id: 70,
                                         created_at: "2026-01-01T00:00:00Z", finished_at: nil)

    Dir.mktmpdir("queue-ledger-fields") do |dir|
      path = File.join(dir, "queue_ledger.json")
      described_class.write(path, records: [record], controls: [])

      written = JSON.parse(File.read(path)).fetch("records").first
      expect(written.keys).to match_array(%w[database queue job_class kind job_id active_job_id execution_id created_at finished_at])
      expect(written.keys).not_to include("arguments", "error")
    end
  end
end


RSpec.describe TimekeepingQueueLedger::Session do
  # "A suite with no active ledger runs unchanged"
  it "an inactive session's before_reset! collects nothing and writes no ledger file" do
    calls = []
    collectors = {
      "monolith" => -> { calls << :monolith; [] },
      "timekeeping" => -> { calls << :timekeeping; [] }
    }

    Dir.mktmpdir("queue-ledger-inactive") do |dir|
      path = File.join(dir, "queue_ledger.json")
      session = described_class.new(path:, collectors:, live: -> { true })

      expect { session.before_reset! }.not_to raise_error
      expect(calls).to eq([])
      expect(File.exist?(path)).to be(false)
    end
  end
end


RSpec.describe TimekeepingQueueLedger::Session do
  # "As a backstop, it raises if a runtime is still live during a reset."
  it "an active session's before_reset! raises while a runtime is live and collects nothing" do
    calls = []
    collectors = {
      "monolith" => -> { calls << :monolith; [] },
      "timekeeping" => -> { calls << :timekeeping; [] }
    }

    Dir.mktmpdir("queue-ledger-live") do |dir|
      session = described_class.new(path: File.join(dir, "queue_ledger.json"), collectors:, live: -> { true })
      session.activate!(env: {})

      expect { session.before_reset! }.to raise_error(StandardError)
      expect(calls).to eq([])
    end
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
end


RSpec.describe TimekeepingDatabaseReset do
  # "Every reset path, including the seeded committed reset, collects executions before it deletes"
  # The name guard must still refuse an unsafe database before any collect or connection.
  it "the Timekeeping database reset never calls before_truncate for a database whose name is not a test database" do
    calls = []
    hook = -> { calls << :collect }

    expect do
      described_class.reset!("legacy", env: { "TIMEKEEPING_DATABASE_URL" => "dbname=timekeeping_production" },
                                       before_truncate: hook)
    end.to raise_error(TestDatabaseGuard::NotATestDatabase)
    expect(calls).to eq([])
  end
end


RSpec.describe "Timekeeping queue ledger probe run: control ran", :without_transaction do
  it "a probe that marks its default control finished between resets exits non-zero naming the control" do
    skip "set TIMEKEEPING_LIVE=1 to run the queue ledger probes" unless ENV["TIMEKEEPING_LIVE"] == "1"

    Dir.mktmpdir("queue-ledger-probe") do |dir|
      probe = Rails.root.join("spec/fixtures/timekeeping_harness/queue_ledger_probe.rb").to_s
      env = { "QUEUE_LEDGER_PROBE" => "control_ran", "TIMEKEEPING_QUEUE_LEDGER_PATH" => File.join(dir, "queue_ledger.json") }
      stdout, stderr, status = Open3.capture3(env, "bundle", "exec", "rspec", probe, chdir: Rails.root.to_s)
      output = "#{stdout}\n#{stderr}"

      # "A probe that marks its `default` control finished between resets exits non-zero."
      expect(status).not_to be_success, output
      expect(output).to match(/control/i)
      expect(output).to include("UpdateInvoiceStatusToOverdueJob")
    end
  end
end


RSpec.describe "Timekeeping queue ledger probe run: non-dedicated job", :without_transaction do
  it "a probe with a completed non-dedicated job exits non-zero and records it in its own ledger file" do
    skip "set TIMEKEEPING_LIVE=1 to run the queue ledger probes" unless ENV["TIMEKEEPING_LIVE"] == "1"

    Dir.mktmpdir("queue-ledger-probe") do |dir|
      ledger_path = File.join(dir, "queue_ledger.json")
      probe = Rails.root.join("spec/fixtures/timekeeping_harness/queue_ledger_probe.rb").to_s
      env = { "QUEUE_LEDGER_PROBE" => "non_dedicated", "TIMEKEEPING_QUEUE_LEDGER_PATH" => ledger_path }
      stdout, stderr, status = Open3.capture3(env, "bundle", "exec", "rspec", probe, chdir: Rails.root.to_s)
      output = "#{stdout}\n#{stderr}"

      # "A completed job on any non-dedicated queue fails it, in either database"
      expect(status).not_to be_success, output
      expect(File.exist?(ledger_path)).to be(true)
      records = JSON.parse(File.read(ledger_path)).fetch("records")
      expect(records.any? { |record| record["queue"] == "default" && record["database"] == "monolith" }).to be(true)
    end
  end
end


RSpec.describe "Timekeeping queue ledger probe run: clean", :without_transaction do
  it "a clean queue ledger probe exits zero" do
    skip "set TIMEKEEPING_LIVE=1 to run the queue ledger probes" unless ENV["TIMEKEEPING_LIVE"] == "1"

    Dir.mktmpdir("queue-ledger-probe") do |dir|
      probe = Rails.root.join("spec/fixtures/timekeeping_harness/queue_ledger_probe.rb").to_s
      env = { "QUEUE_LEDGER_PROBE" => "clean", "TIMEKEEPING_QUEUE_LEDGER_PATH" => File.join(dir, "queue_ledger.json") }
      stdout, stderr, status = Open3.capture3(env, "bundle", "exec", "rspec", probe, chdir: Rails.root.to_s)
      output = "#{stdout}\n#{stderr}"

      # "A clean probe exits zero."
      expect(status).to be_success, output
      expect(output).to include("0 failures")
    end
  end
end


RSpec.describe "Timekeeping queue ledger session finish" do
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
end


RSpec.describe "Timekeeping queue ledger reset paths" do
  it "delete_all_committed! and the committed_data reset collect before they delete" do
    steps = []
    allow(TestDatabaseCleanup).to receive(:before_reset!) { steps << :collect }
    allow(DatabaseCleaner).to receive(:clean_with) { steps << :delete }
    allow(TimekeepingOwnership).to receive(:ensure_initial!)

    # "Every reset path, including the seeded committed reset, collects executions before it deletes"
    TestDatabaseCleanup.delete_all_committed!
    expect(steps).to eq(%i[collect delete])

    steps.clear
    CommittedDataMode.reset_database
    expect(steps).to eq(%i[collect delete])
  end
end


RSpec.describe "Timekeeping queue ledger Timekeeping reset path" do
  it "the Timekeeping database reset calls before_truncate once before it connects to a test database" do
    steps = []
    allow(PG).to receive(:connect) do
      steps << :connect
      raise PG::ConnectionBad, 'database "queue_ledger_never_created_test" does not exist'
    end

    # "Every reset path, including the seeded committed reset, collects executions before it deletes"
    result = TimekeepingDatabaseReset.reset!(
      "legacy",
      env: { "TIMEKEEPING_DATABASE_URL" => "dbname=queue_ledger_never_created_test" },
      before_truncate: -> { steps << :collect }
    )

    expect(result).to be_nil
    expect(steps).to eq(%i[collect connect])
  end
end


RSpec.describe TimekeepingQueueLedger do
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
end


RSpec.describe TimekeepingQueueLedger do
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
end


RSpec.describe TimekeepingQueueLedger do
  it "verdict keeps dedicated queues per database so invoice_operations fails only in Timekeeping" do
    now = Time.utc(2026, 1, 1).iso8601
    record_in = lambda do |database|
      described_class::Record.new(database:, queue: "invoice_operations", job_class: "RecoverInvoiceOperationIntentsJob",
                                  kind: "completed", job_id: 31, active_job_id: SecureRandom.uuid, execution_id: nil,
                                  created_at: now, finished_at: now)
    end
    controls = [
      described_class::Control.new(queue: "default", job_class: "UpdateInvoiceStatusToOverdueJob", job_id: 1,
                                   active_job_id: SecureRandom.uuid, status: "unrun"),
      described_class::Control.new(queue: "billing_sync", job_class: "SyncStripeSubscriptionCompanyJob", job_id: 2,
                                   active_job_id: SecureRandom.uuid, status: "unrun")
    ]

    # "The monolith allows `invoice_operations` and `timekeeping_relay`. Timekeeping allows only `timekeeping_relay`."
    monolith = described_class.verdict(records: [record_in.call("monolith")], controls:,
                                       dedicated_queues: described_class::DEDICATED_QUEUES)
    timekeeping = described_class.verdict(records: [record_in.call("timekeeping")], controls:,
                                          dedicated_queues: described_class::DEDICATED_QUEUES)

    expect(monolith.passed?).to be(true)
    expect(timekeeping.passed?).to be(false)
  end
end


RSpec.describe TimekeepingQueueLedger do
  it "parse raises UnreadableLedger for a half-written ledger and for valid JSON of the wrong shape" do
    # "Any failure, or a ledger file that cannot be parsed, raises, and the run exits non-zero."
    expect { described_class.parse('{"records": [{"database": "monolith"') }
      .to raise_error(described_class::UnreadableLedger)
    expect { described_class.parse("[]") }.to raise_error(described_class::UnreadableLedger)
  end
end


RSpec.describe TimekeepingQueueLedger do
  it "write twice keeps the first record and leaves no temp file beside the ledger" do
    now = Time.utc(2026, 1, 1).iso8601
    record = lambda do |job_id|
      described_class::Record.new(database: "monolith", queue: "default", job_class: "UpdateInvoiceStatusToOverdueJob",
                                  kind: "completed", job_id:, active_job_id: SecureRandom.uuid, execution_id: nil,
                                  created_at: now, finished_at: now)
    end

    Dir.mktmpdir("queue-ledger-write") do |dir|
      path = File.join(dir, "queue_ledger.json")
      # "It adds what it finds to tmp/timekeeping-integration/queue_ledger.json, outside the cleaned tables."
      described_class.write(path, records: [record.call(41)], controls: [])
      described_class.write(path, records: [record.call(42)], controls: [])

      parsed = described_class.parse(File.read(path))
      expect(parsed[:records].map(&:job_id)).to contain_exactly(41, 42)
      # "Rewrite it atomically, with a temp file and a rename."
      expect(Dir.children(dir)).to eq(["queue_ledger.json"])
    end
  end
end


RSpec.describe TimekeepingQueueLedger::Session do
  it "an inactive session before_reset! touches no collector and writes no ledger file" do
    untouchable = Class.new(BasicObject) do
      def method_missing(name, *) = ::Kernel.raise("collector used: #{name}")
      def respond_to_missing?(*) = true
    end.new

    Dir.mktmpdir("queue-ledger-inactive") do |dir|
      path = File.join(dir, "queue_ledger.json")
      session = described_class.new(path:, collectors: untouchable, live: -> { raise "live check used" })

      # "A suite with no active ledger runs unchanged"
      expect { session.before_reset! }.not_to raise_error
      expect(File.exist?(path)).to be(false)
    end
  end
end


RSpec.describe TimekeepingQueueLedger::Session do
  it "an active session before_reset! raises while a runtime is live and collects nothing first" do
    used = []
    recording = Class.new(BasicObject) do
      define_method(:method_missing) do |name, *|
        used << name
        []
      end
      define_method(:respond_to_missing?) { |*| true }
    end.new

    Dir.mktmpdir("queue-ledger-live") do |dir|
      path = File.join(dir, "queue_ledger.json")
      session = described_class.new(path:, collectors: recording, live: -> { true })
      session.activate!(env: { "TIMEKEEPING_DATABASE_URL" => "dbname=timekeeping_queue_ledger_live_test" })

      # "As a backstop, it raises if a runtime is still live during a reset."
      expect { session.before_reset! }.to raise_error(StandardError)
      expect(used).to eq([])
    end
  end
end


RSpec.describe TimekeepingDatabaseReset do
  it "reset! refuses a non-test database before it runs the collect hook" do
    calls = []

    expect do
      described_class.reset!("legacy", env: { "TIMEKEEPING_DATABASE_URL" => "dbname=timekeeping_production" },
                                       before_truncate: -> { calls << :collect })
    end.to raise_error(TestDatabaseGuard::NotATestDatabase)
    expect(calls).to eq([])
  end
end


RSpec.describe TimekeepingQueueLedger::Session, :without_transaction do
  # "In each window between resets it enqueues one `default` and one `billing_sync` control job. Before the reset it checks that both still exist and have not run."
  it "a default control that finishes between resets fails finish! even when no collector reports it" do
    Dir.mktmpdir("queue-ledger-control-ran") do |dir|
      session = described_class.new(path: File.join(dir, "queue_ledger.json"),
                                    collectors: { "monolith" => -> { [] }, "timekeeping" => -> { [] } },
                                    live: -> { false })
      session.activate!(env: ENV.to_h)
      session.open_window!
      SolidQueue::Job.where(queue_name: "default", class_name: "UpdateInvoiceStatusToOverdueJob")
                     .update_all(finished_at: Time.current)
      session.before_reset!

      expect { session.finish! }.to raise_error(StandardError, /control/i)
    end
  end
end


RSpec.describe TimekeepingQueueLedger::Session, :without_transaction do
  # "Before the reset it checks that both still exist and have not run."
  # "A missing control or an unparsable tmp/timekeeping-integration/queue_ledger.json fails the suite"
  it "a control seen unrun at stop and deleted before the reset still fails finish! as missing" do
    Dir.mktmpdir("queue-ledger-control-missing") do |dir|
      session = described_class.new(path: File.join(dir, "queue_ledger.json"),
                                    collectors: { "monolith" => -> { [] }, "timekeeping" => -> { [] } },
                                    live: -> { false })
      session.activate!(env: ENV.to_h)
      session.open_window!
      session.observe_controls!
      SolidQueue::Job.where(queue_name: "default", class_name: "UpdateInvoiceStatusToOverdueJob").delete_all
      session.before_reset!

      expect { session.finish! }.to raise_error(StandardError, /missing/i)
    end
  end
end


RSpec.describe TimekeepingQueueLedger::Session, :without_transaction do
  # "A job enqueued by other code never stands in for a control."
  it "another code's unrun default job does not stand in for a deleted default control at the reset check" do
    Dir.mktmpdir("queue-ledger-stand-in") do |dir|
      session = described_class.new(path: File.join(dir, "queue_ledger.json"),
                                    collectors: { "monolith" => -> { [] }, "timekeeping" => -> { [] } },
                                    live: -> { false })
      session.activate!(env: ENV.to_h)
      session.open_window!
      SolidQueue::Job.where(queue_name: "default", class_name: "UpdateInvoiceStatusToOverdueJob").delete_all
      ActiveJob::QueueAdapters::SolidQueueAdapter.new.enqueue(UpdateInvoiceStatusToOverdueJob.new)
      session.before_reset!

      expect { session.finish! }.to raise_error(StandardError, /missing/i)
    end
  end
end


RSpec.describe TimekeepingQueueLedger::Session do
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
end


RSpec.describe TimekeepingQueueLedger::Session do
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


RSpec.describe TimekeepingQueueLedger::Session, :without_transaction do
  # "Use `ActiveJob::QueueAdapters::SolidQueueAdapter.new.enqueue`, with `UpdateInvoiceStatusToOverdueJob` on `default` and `SyncStripeSubscriptionCompanyJob` on `billing_sync`."
  it "open_window! commits one default and one billing_sync control that a clean reset records as unrun" do
    Dir.mktmpdir("queue-ledger-open-window") do |dir|
      path = File.join(dir, "queue_ledger.json")
      session = described_class.new(path:, collectors: {}, live: -> { false })
      session.activate!(env: {})
      session.open_window!

      jobs = SolidQueue::Job.where(class_name: %w[UpdateInvoiceStatusToOverdueJob SyncStripeSubscriptionCompanyJob])
      expect(jobs.pluck(:class_name, :queue_name)).to contain_exactly(
        %w[UpdateInvoiceStatusToOverdueJob default], %w[SyncStripeSubscriptionCompanyJob billing_sync]
      )

      session.before_reset!
      controls = TimekeepingQueueLedger.parse(File.read(path))[:controls]
      expect(controls.map(&:status)).to eq(%w[unrun unrun])
      expect(controls.map(&:active_job_id)).to match_array(jobs.pluck(:active_job_id))
      expect { session.finish! }.not_to raise_error
    end
  end
end


RSpec.describe TimekeepingQueueLedger::Session, :without_transaction do
  # "Before the reset it checks that both still exist and have not run."
  it "a billing_sync control with a claimed execution and a default control with a failed execution both check as ran" do
    Dir.mktmpdir("queue-ledger-claimed-failed") do |dir|
      path = File.join(dir, "queue_ledger.json")
      session = described_class.new(path:, collectors: {}, live: -> { false })
      session.activate!(env: {})
      session.open_window!
      default_job = SolidQueue::Job.find_by!(class_name: "UpdateInvoiceStatusToOverdueJob")
      billing_job = SolidQueue::Job.find_by!(class_name: "SyncStripeSubscriptionCompanyJob")
      process = SolidQueue::Process.create!(kind: "Worker", last_heartbeat_at: Time.current, pid: Process.pid,
                                            hostname: "queue-ledger-spec", name: "queue-ledger-spec-#{Process.pid}")
      SolidQueue::ReadyExecution.where(job_id: billing_job.id).delete_all
      SolidQueue::ClaimedExecution.create!(job_id: billing_job.id, process_id: process.id)
      SolidQueue::ReadyExecution.where(job_id: default_job.id).delete_all
      SolidQueue::FailedExecution.create!(job_id: default_job.id, error: { "message" => "boom" })

      session.before_reset!

      controls = TimekeepingQueueLedger.parse(File.read(path))[:controls]
      expect(controls.map(&:status)).to eq(%w[ran ran])
    end
  end
end


RSpec.describe TimekeepingQueueLedger::MonolithCollector, :without_transaction do
  # "it collects claimed, completed and failed Solid Queue executions on any queue other than the dedicated ones"
  it "returns a finished default job and ignores a ready one" do
    adapter = ActiveJob::QueueAdapters::SolidQueueAdapter.new
    finished = UpdateInvoiceStatusToOverdueJob.new
    ready = UpdateInvoiceStatusToOverdueJob.new
    adapter.enqueue(finished)
    adapter.enqueue(ready)
    SolidQueue::Job.find_by!(active_job_id: finished.job_id).update!(finished_at: Time.current)

    records = described_class.collect

    expect(records.map(&:active_job_id)).to eq([finished.job_id])
    expect(records.first).to have_attributes(database: "monolith", queue: "default", kind: "completed")
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


RSpec.describe "Timekeeping queue ledger reset hooks" do
  # "Every reset path, including the seeded committed reset, collects executions before it deletes"
  it "the without_transaction and two_tenant_seed hooks collect before each of their truncates" do
    steps = []
    allow(TestDatabaseCleanup).to receive(:before_reset!) { steps << :collect }
    allow(DatabaseCleaner).to receive(:clean_with) { steps << :delete }
    allow(TimekeepingOwnership).to receive(:ensure_initial!)
    allow(Timekeeping::SeedDispositionRecorder).to receive(:load_fresh_seed!)
    allow(TestDatabaseCleanup).to receive(:delete_operation_ledger_rows!)

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

RSpec.describe "Timekeeping queue ledger probe fixture" do
  it "keeps the queue ledger probe out of a normal suite run" do
    probe = Rails.root.join("spec/fixtures/timekeeping_harness/queue_ledger_probe.rb")

    expect(probe).to exist
    expect(probe.basename.to_s).not_to end_with("_spec.rb")
  end
end
