# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "json"
require "tmpdir"

RSpec.describe TimekeepingDemo::Regression do
  context "more tests 10" do
    it "a hostile state after a valid one raises ArgumentError before any child is spawned" do
      calls = []
      runner = ->(env:, argv:) { calls << [env, argv]; true }

      # "Refuse a state outside legacy/timekeeping/rollback with `ArgumentError` before anything is spawned."
      ["legacy; rm -rf /", "", "LEGACY", "bogus"].each do |bad|
        expect do
          described_class.run(runner:, states: ["legacy", bad], specs: ["spec/models/invoice_spec.rb"])
        end.to raise_error(ArgumentError)
      end

      expect(calls).to be_empty
    end
  end

  context "more tests 11" do
    it "gives a repeated regression run fresh ledger paths that share nothing with the first run" do
      recorded = []
      runner = lambda do |env:, argv:|
        _ = argv
        recorded << env.fetch("TIMEKEEPING_QUEUE_LEDGER_PATH")
        true
      end

      first_status = nil
      second_status = nil
      expect do
        first_status = described_class.run(runner:)
        second_status = described_class.run(runner:)
      end.to output.to_stdout

      expect([first_status, second_status]).to eq([0, 0])
      expect(recorded.size).to eq(8)
      first_run, second_run = recorded.each_slice(4).to_a
      # "its own `TIMEKEEPING_QUEUE_LEDGER_PATH` in a fresh temp directory"
      expect(first_run & second_run).to be_empty
      expect(recorded.map { |path| File.dirname(path) }.uniq.size).to eq(8)
      # The temp directories are removed once each child has finished.
      expect(recorded.map { |path| File.dirname(path) }).to all(satisfy { |dir| !File.exist?(dir) })
    end
  end

  context "more tests 14" do
    it "only true passes a state: a last state of false, nil, or a truthy 0 returns 1, and all true returns 0" do
      run_with_last = lambda do |last_result|
        states_called = []
        runner = lambda do |env:, argv:|
          state = env["TIMEKEEPING_OWNER_STATE"]
          next true if state == "" && argv.include?("switches_owner")

          states_called << state
          state == "rollback" ? last_result : true
        end
        status = nil
        expect { status = described_class.run(runner:, specs: ["spec/models/invoice_spec.rb"]) }.to output.to_stdout
        [status, states_called]
      end

      # "Only `true` counts as a pass; `false` and `nil` (spawn failure, killed by a signal) fail."
      [false, nil, 0].each do |last_result|
        status, states_called = run_with_last.call(last_result)
        expect(states_called).to eq(%w[legacy timekeeping rollback])
        expect(status).to eq(1), "expected #{last_result.inspect} to fail the rollback state"
      end

      status, = run_with_last.call(true)
      expect(status).to eq(0)
    end
  end

  context "more tests 16" do
    it "the switches_owner report prints none when its pass writes no examples or no file at all" do
      empty_report = lambda do |env:, argv:|
        next true unless argv.include?("switches_owner")

        File.write(argv[argv.index("--out") + 1], JSON.generate("examples" => []))
        true
      end
      status = nil
      # "print the example ids from that file under a separate heading, or \"none\""
      expect { status = described_class.run(runner: empty_report, specs: ["spec/models/invoice_spec.rb"]) }
        .to output(/^none$/).to_stdout
      expect(status).to eq(0)

      spawn_failed = ->(env:, argv:) { argv.include?("switches_owner") ? nil : true }
      expect { status = described_class.run(runner: spawn_failed, specs: ["spec/models/invoice_spec.rb"]) }
        .to output(/^none$/).to_stdout
      expect(status).to eq(1)
    end
  end

  context "more tests 17" do
    it "SPECS is exactly the section 12.1 list plus the three characterization specs, and STATES matches the owner-state harness" do
      # "A spec that cannot run in some environment is never removed from the list."
      section_12_1 = %w[
        spec/models/timesheet_entry_spec.rb
        spec/policies/timesheet_entry_policy_spec.rb
        spec/requests/api/v1/timesheet_entries/bulk_actions/update_spec.rb
        spec/requests/api/v1/timesheet_entries/bulk_actions/destroy_spec.rb
        spec/requests/api/v1/timesheet_entry/index_spec.rb
        spec/requests/api/v1/cli/timesheet_entries/create_spec.rb
        spec/requests/api/v1/cli/timesheet_entries/update_spec.rb
        spec/requests/api/v1/cli/timesheet_entries/destroy_spec.rb
        spec/mcp/tools/write_tools_spec.rb
        spec/mcp/idempotency_store_spec.rb
        spec/requests/api/v1/agent/timesheet_entries/create_spec.rb
        spec/requests/api/v1/invoices/create_spec.rb
        spec/models/invoice_spec.rb
        spec/models/invoice_line_item_spec.rb
        spec/requests/api/v1/invoices/send_invoice_spec.rb
        spec/system/invoices/send_invoice_spec.rb
        spec/services/imports/harvest_time_entries_importer_spec.rb
        spec/services/reports/time_entries/
        spec/services/analytics/team_productivity_analytics_spec.rb
        spec/services/metrics/data_builder_spec.rb
      ]
      characterization = %w[
        spec/characterization/invoice_entry_locking_spec.rb
        spec/characterization/timesheet_entry_rules_spec.rb
        spec/characterization/entry_lookups_and_pdf_totals_spec.rb
      ]

      expect(described_class::SPECS).to be_frozen
      expect(described_class::SPECS).to match_array(section_12_1 + characterization)
      expect(described_class::SPECS.uniq.size).to eq(described_class::SPECS.size)
      expect(described_class::SPECS.grep(/gateway_spec\.rb\z/)).to be_empty
      expect(described_class::STATES).to eq(%w[legacy timekeeping rollback])
      expect(described_class::STATES).to match_array(TimekeepingOwnerState::STATES.keys.map(&:to_s))
    end
  end

  context "more tests 19" do
    # "Run every state in the given order, one at a time, even after a failure, and print each state's result."
    it "keeps running the later states after the middle state fails and returns EX_FAILURE" do
      states_run = []
      runner = lambda do |env:, argv:|
        next true if argv.include?("switches_owner")

        states_run << env.fetch("TIMEKEEPING_OWNER_STATE")
        env.fetch("TIMEKEEPING_OWNER_STATE") != "timekeeping"
      end
      status = nil

      expect do
        status = described_class.run(runner:, states: %w[legacy timekeeping rollback],
                                     specs: ["spec/models/invoice_spec.rb"])
      end.to output(/^legacy: passed$.*^timekeeping: failed$.*^rollback: passed$/m).to_stdout

      expect(states_run).to eq(%w[legacy timekeeping rollback])
      expect(status).to eq(TimekeepingDemo::CLI::EX_FAILURE)
    end
  end

  context "more tests 21" do
    # "Only `true` counts as a pass; `false` and `nil` (spawn failure, killed by a signal) fail."
    it "counts a nil or truthy non-true runner result as a failed state" do
      [nil, 0, "true"].each do |bad_result|
        runner = lambda do |env:, argv:|
          next true if argv.include?("switches_owner")

          env.fetch("TIMEKEEPING_OWNER_STATE") == "legacy" ? bad_result : true
        end
        status = nil

        expect do
          status = described_class.run(runner:, states: %w[legacy timekeeping rollback],
                                       specs: ["spec/models/invoice_spec.rb"])
        end.to output(/^legacy: failed$.*^timekeeping: passed$/m).to_stdout

        expect(status).to eq(TimekeepingDemo::CLI::EX_FAILURE), "result #{bad_result.inspect} was counted as a pass"
      end
    end
  end

  context "more tests 23" do
    # "Run one more pass with `--tag switches_owner --format json --out <tmp file>` and no owner state; print the example
    # ids from that file under a separate heading, or \"none\". A failure in that pass also returns `EX_FAILURE`"
    it "still lists the switches_owner ids a failed report pass wrote and returns EX_FAILURE" do
      tagged_id = "./spec/models/invoice_spec.rb[1:2]"
      runner = lambda do |env:, argv:|
        next true unless argv.include?("switches_owner")

        out = argv[argv.index("--out") + 1]
        File.write(out, JSON.generate("examples" => [{ "id" => tagged_id, "status" => "failed" }]))
        false
      end
      status = nil

      expect do
        status = described_class.run(runner:, states: %w[legacy timekeeping rollback],
                                     specs: ["spec/models/invoice_spec.rb"])
      end.to output(include(tagged_id)).to_stdout

      expect(status).to eq(TimekeepingDemo::CLI::EX_FAILURE)
    end
  end

  context "with environment keys written out for the stdlib-only bin script" do
    it "names the same owner-state and ledger keys the spec harness reads" do
      expect(described_class::OWNER_STATE_KEY).to eq(TimekeepingOwnerState::ENV_KEY)
      expect(described_class::LEDGER_PATH_KEY).to eq(TimekeepingQueueLedger::PATH_KEY)
    end

    it "uses the CLI's exit statuses" do
      expect(described_class::EX_OK).to eq(TimekeepingDemo::CLI::EX_OK)
      expect(described_class::EX_FAILURE).to eq(TimekeepingDemo::CLI::EX_FAILURE)
    end

    it "gives each state run the spec list followed by the switches_owner exclusion as separate arguments" do
      calls = []
      runner = ->(env:, argv:) { calls << [env, argv] and true }

      expect { described_class.run(runner:, states: %w[legacy], specs: ["spec/models/invoice_spec.rb"]) }
        .to output.to_stdout

      state_env, state_argv = calls.first
      expect(state_argv).to eq(["spec/models/invoice_spec.rb", "--tag", "~switches_owner"])
      expect(state_env).to include("TIMEKEEPING_OWNER_STATE" => "legacy")
      _, report_argv = calls.last
      expect(report_argv.first(5)).to eq(["spec/models/invoice_spec.rb", "--tag", "switches_owner", "--format", "json"])
      expect(report_argv[5]).to eq("--out")
      # Keeps rspec's failure details on stdout beside the json report.
      expect(report_argv.last(2)).to eq(["--format", "progress"])
    end
  end

  it "leaves the parent's queue ledger in place when every child deletes its own ledger at suite start" do
    ledger_key = "TIMEKEEPING_QUEUE_LEDGER_PATH"
    Dir.mktmpdir("regression-parent-ledger") do |dir|
      parent_ledger = File.join(dir, "queue_ledger.json")
      File.write(parent_ledger, "parent ledger contents")
      child_paths = []
      # Stands in for a child rspec: its suite start removes whatever ledger
      # path its merged environment names.
      runner = lambda do |env:, argv:|
        _ = argv
        path = ENV.to_h.merge(env).fetch(ledger_key)
        child_paths << path
        FileUtils.rm_f(path)
        true
      end

      previous = ENV.fetch(ledger_key, nil)
      begin
        ENV[ledger_key] = parent_ledger
        # "Each child env sets `TIMEKEEPING_OWNER_STATE` to its state (overriding any caller value), `TIMEKEEPING_REGRESSION=1`, `TIMEKEEPING_LIVE=1`, and its own `TIMEKEEPING_QUEUE_LEDGER_PATH` in a fresh temp directory (a child rspec that inherits the parent's ledger path deletes the parent's ledger at suite start)."
        expect { described_class.run(runner:) }.to output.to_stdout
      ensure
        ENV[ledger_key] = previous
      end

      expect(child_paths.size).to eq(4)
      expect(child_paths.uniq.size).to eq(4)
      expect(child_paths).not_to include(parent_ledger)
      expect(File.read(parent_ledger)).to eq("parent ledger contents")
    end
  end

  context "more tests 2" do
    it "each child env carries its own owner state, REGRESSION and LIVE set to 1, and a distinct temp ledger path" do
      calls = []
      runner = lambda do |env:, argv:|
        calls << { env: env.dup, argv: argv.dup }
        true
      end
      expect { described_class.run(runner:, specs: ["spec/models/invoice_spec.rb"]) }.to output.to_stdout

      state_calls = calls.select { |call| call[:argv].include?("~switches_owner") }
      # "Each child env sets `TIMEKEEPING_OWNER_STATE` to its state (overriding any caller value), `TIMEKEEPING_REGRESSION=1`, `TIMEKEEPING_LIVE=1`, and its own `TIMEKEEPING_QUEUE_LEDGER_PATH` in a fresh temp directory (a child rspec that inherits the parent's ledger path deletes the parent's ledger at suite start)."
      expect(state_calls.map { |call| call[:env]["TIMEKEEPING_OWNER_STATE"] }).to eq(%w[legacy timekeeping rollback])
      calls.each do |call|
        expect(call[:env]["TIMEKEEPING_REGRESSION"]).to eq("1")
        expect(call[:env]["TIMEKEEPING_LIVE"]).to eq("1")
        expect(call[:env]["TIMEKEEPING_QUEUE_LEDGER_PATH"]).to start_with(File.realpath(Dir.tmpdir)).or start_with(Dir.tmpdir)
      end
      ledger_paths = calls.map { |call| call[:env]["TIMEKEEPING_QUEUE_LEDGER_PATH"] }
      expect(ledger_paths.size).to eq(4)
      expect(ledger_paths.uniq.size).to eq(4)
    end
  end

  context "more tests 3" do
    it "the switches_owner pass runs once with no owner state, lists the ids from its json file, and its failure returns 1" do
      report_calls = []
      runner = lambda do |env:, argv:|
        next true unless argv.include?("switches_owner")

        report_calls << { env: env.dup, argv: argv.dup }
        out = argv[argv.index("--out") + 1]
        File.write(out, JSON.generate("examples" => [
          { "id" => "./spec/models/invoice_spec.rb[1:4]", "status" => "failed" },
          { "id" => "./spec/models/invoice_spec.rb[1:7]", "status" => "passed" }
        ]))
        false
      end

      status = nil
      # "Run one more pass with `--tag switches_owner --format json --out <tmp file>` and no owner state; print the example ids from that file under a separate heading, or \"none\". A failure in that pass also returns `EX_FAILURE`"
      expect { status = described_class.run(runner:, specs: ["spec/models/invoice_spec.rb"]) }
        .to output(%r{switches_owner.*\./spec/models/invoice_spec\.rb\[1:4\].*\./spec/models/invoice_spec\.rb\[1:7\]}m).to_stdout

      expect(report_calls.size).to eq(1)
      argv = report_calls.first[:argv]
      expect(argv[argv.index("--tag") + 1]).to eq("switches_owner")
      expect(argv[argv.index("--format") + 1]).to eq("json")
      expect(argv).not_to include("--fail-if-no-examples")
      # A key that is set, even to "", is one dotenv never fills, so the report
      # child must receive the key rather than have it removed.
      expect(report_calls.first[:env]).to have_key("TIMEKEEPING_OWNER_STATE")
      expect(report_calls.first[:env]).to include("TIMEKEEPING_OWNER_STATE" => "")
      expect(status).to eq(1)
    end
  end
end
