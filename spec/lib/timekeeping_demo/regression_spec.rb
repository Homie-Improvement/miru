# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "json"
require "tmpdir"

RSpec.describe TimekeepingDemo::Regression do
  # A stub report pass that runs no tagged example still writes the json
  # report a real rspec run writes, so the command can read it.
  def write_empty_switches_owner_report(argv)
    File.write(argv[argv.index("--out") + 1], JSON.generate("examples" => []))
  end

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
        recorded << env.fetch("TIMEKEEPING_QUEUE_LEDGER_PATH")
        write_empty_switches_owner_report(argv) if argv.include?("switches_owner")
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
          if state.nil? && argv.include?("switches_owner")
            write_empty_switches_owner_report(argv)
            next true
          end

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
    it "the switches_owner report prints none for a written empty report and unreadable when its pass writes no file" do
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
        .to output(/^unreadable report: /).to_stdout
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
        if argv.include?("switches_owner")
          write_empty_switches_owner_report(argv)
          next true
        end

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
          if argv.include?("switches_owner")
            write_empty_switches_owner_report(argv)
            next true
          end

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
      expect(report_calls.first[:env]).to include("TIMEKEEPING_OWNER_STATE" => nil)
      expect(status).to eq(1)
    end
  end
end

RSpec.describe TimekeepingDemo::Regression do
  it "fails the command and says the report is unreadable when the switches_owner pass returns true but writes no report" do
    runner = ->(env:, argv:) { true }
    status = nil

    # "The plan says missing or unparseable reports fail the command. The author's declined answer and
    # run_switches_owner_report instead allow success without a readable report when the runner returns true."
    expect { status = described_class.run(runner:, specs: ["spec/models/invoice_spec.rb"]) }
      .to output(/^unreadable report: /).to_stdout
    expect(status).to eq(described_class::EX_FAILURE)
  end
end

RSpec.describe TimekeepingDemo::Regression do
  it "fails the command when the switches_owner pass returns true but its report is not valid JSON" do
    ["not json", "", "{\"examples\":[{\"id\":"].each do |contents|
      runner = lambda do |env:, argv:|
        next true unless argv.include?("switches_owner")

        File.write(argv[argv.index("--out") + 1], contents)
        true
      end
      status = nil

      # "The plan says missing or unparseable reports fail the command."
      expect { status = described_class.run(runner:, specs: ["spec/models/invoice_spec.rb"]) }
        .to output(/^unreadable report: /).to_stdout
      expect(status).to eq(described_class::EX_FAILURE), "report #{contents.inspect} was counted as a pass"
    end
  end
end

RSpec.describe TimekeepingDemo::Regression do
  it "fails the command without raising when the switches_owner report path cannot be read as a file" do
    runner = lambda do |env:, argv:|
      next true unless argv.include?("switches_owner")

      Dir.mkdir(argv[argv.index("--out") + 1])
      true
    end
    status = nil

    # "The plan says missing or unparseable reports fail the command."
    expect do
      expect { status = described_class.run(runner:, specs: ["spec/models/invoice_spec.rb"]) }
        .to output(/^unreadable report: /).to_stdout
    end.not_to raise_error
    expect(status).to eq(described_class::EX_FAILURE)
  end
end

RSpec.describe TimekeepingDemo::Regression do
  it "read_report answers UnreadableReport for a missing, malformed or wrongly shaped report and Report for a valid one" do
    Dir.mktmpdir("read-report-acceptance") do |dir|
      missing = File.join(dir, "missing.json")
      expect(described_class.read_report(missing)).to be_a(described_class::UnreadableReport)

      { "malformed.json" => "not json", "empty.json" => "", "shape.json" => JSON.generate("examples" => "x"),
        "array.json" => JSON.generate([]) }.each do |name, contents|
        path = File.join(dir, name)
        File.write(path, contents)
        result = described_class.read_report(path)
        expect(result).to be_a(described_class::UnreadableReport), "#{name} was read as a report"
        expect(result.reason).to be_a(String).and(satisfy { |reason| !reason.empty? })
      end

      valid = File.join(dir, "valid.json")
      File.write(valid, JSON.generate("examples" => [{ "id" => "./spec/models/invoice_spec.rb[1:2]" }]))
      expect(described_class.read_report(valid)).to eq(described_class::Report.new(ids: ["./spec/models/invoice_spec.rb[1:2]"]))

      empty_examples = File.join(dir, "empty_examples.json")
      File.write(empty_examples, JSON.generate("examples" => []))
      expect(described_class.read_report(empty_examples)).to eq(described_class::Report.new(ids: []))
    end
  end
end

RSpec.describe TimekeepingDemo::Regression do
  it "fails the command and says the report is unreadable when the switches_owner runner returns true but writes no report" do
    runner = ->(env:, argv:) { true }
    status = nil

    # "The plan says missing or unparseable reports fail the command. The author's declined answer and
    # run_switches_owner_report instead allow success without a readable report when the runner returns true."
    expect { status = described_class.run(runner:, specs: ["spec/models/invoice_spec.rb"]) }
      .to output(/^unreadable report: /).to_stdout

    expect(status).to eq(described_class::EX_FAILURE)
  end
end

RSpec.describe TimekeepingDemo::Regression do
  it "fails the command when the switches_owner runner returns true but its report is not valid JSON" do
    ["not json", "", "{\"examples\": ["].each do |content|
      runner = lambda do |env:, argv:|
        next true unless argv.include?("switches_owner")

        File.write(argv[argv.index("--out") + 1], content)
        true
      end
      status = nil

      # "The plan says missing or unparseable reports fail the command."
      expect { status = described_class.run(runner:, specs: ["spec/models/invoice_spec.rb"]) }
        .to output(/^unreadable report: /).to_stdout

      expect(status).to eq(described_class::EX_FAILURE), "report content #{content.inspect} was counted as a pass"
    end
  end
end

RSpec.describe TimekeepingDemo::Regression do
  it "fails the command when the switches_owner report is JSON without an examples array" do
    [{ "examples" => "x" }, {}, []].each do |document|
      runner = lambda do |env:, argv:|
        next true unless argv.include?("switches_owner")

        File.write(argv[argv.index("--out") + 1], JSON.generate(document))
        true
      end
      status = nil

      # "The plan says missing or unparseable reports fail the command."
      expect { status = described_class.run(runner:, specs: ["spec/models/invoice_spec.rb"]) }
        .to output(/^unreadable report: /).to_stdout

      expect(status).to eq(described_class::EX_FAILURE), "report #{document.inspect} was counted as a pass"
    end
  end
end

RSpec.describe TimekeepingDemo::Regression do
  it "answers EX_FAILURE without raising when the switches_owner report path cannot be read as a file" do
    runner = lambda do |env:, argv:|
      next true unless argv.include?("switches_owner")

      Dir.mkdir(argv[argv.index("--out") + 1])
      true
    end
    status = nil

    # "The plan says missing or unparseable reports fail the command."
    expect { status = described_class.run(runner:, specs: ["spec/models/invoice_spec.rb"]) }
      .to output(/^unreadable report: /).to_stdout

    expect(status).to eq(described_class::EX_FAILURE)
  end
end

RSpec.describe TimekeepingDemo::Regression do
  it "a second regression run that writes no report fails even after a first run wrote a readable one" do
    write_report = true
    runner = lambda do |env:, argv:|
      next true unless argv.include?("switches_owner")

      File.write(argv[argv.index("--out") + 1], JSON.generate("examples" => [])) if write_report
      true
    end
    first_status = nil
    second_status = nil

    # "The plan says missing or unparseable reports fail the command."
    expect { first_status = described_class.run(runner:, specs: ["spec/models/invoice_spec.rb"]) }
      .to output(/^none$/).to_stdout
    write_report = false
    expect { second_status = described_class.run(runner:, specs: ["spec/models/invoice_spec.rb"]) }
      .to output(/^unreadable report: /).to_stdout

    expect([first_status, second_status]).to eq([described_class::EX_OK, described_class::EX_FAILURE])
  end
end

RSpec.describe TimekeepingDemo::Regression do
  it "read_report answers the ids of a readable report and an unreadable result with a reason for a missing or malformed one" do
    Dir.mktmpdir("read-report") do |dir|
      readable = File.join(dir, "readable.json")
      File.write(readable, JSON.generate("examples" => [{ "id" => "./spec/models/invoice_spec.rb[1:4]" }]))
      empty = File.join(dir, "empty.json")
      File.write(empty, JSON.generate("examples" => []))
      malformed = File.join(dir, "malformed.json")
      File.write(malformed, "not json")
      wrong_shape = File.join(dir, "wrong_shape.json")
      File.write(wrong_shape, JSON.generate("examples" => "x"))

      expect(described_class.read_report(readable))
        .to eq(described_class::Report.new(ids: ["./spec/models/invoice_spec.rb[1:4]"]))
      expect(described_class.read_report(empty)).to eq(described_class::Report.new(ids: []))

      # "The plan says missing or unparseable reports fail the command."
      [File.join(dir, "missing.json"), malformed, wrong_shape, dir].each do |path|
        result = described_class.read_report(path)
        expect(result).to be_a(described_class::UnreadableReport), "#{path} was read as a report"
        expect(result.reason).to be_a(String).and(satisfy { |reason| !reason.empty? })
      end
    end
  end
end

RSpec.describe TimekeepingDemo::Regression do
  it "fails the command when the switches_owner runner returns true but writes no report file" do
    runner = ->(env:, argv:) { true }
    status = nil

    # "The plan says missing or unparseable reports fail the command. The author's declined answer and
    # run_switches_owner_report instead allow success without a readable report when the runner returns true."
    expect { status = described_class.run(runner:, specs: ["spec/models/invoice_spec.rb"]) }
      .to output(/^unreadable report: /).to_stdout

    expect(status).to eq(described_class::EX_FAILURE)
  end
end

RSpec.describe TimekeepingDemo::Regression do
  it "fails the command when the switches_owner runner returns true and its report is not valid JSON" do
    runner = lambda do |env:, argv:|
      File.write(argv[argv.index("--out") + 1], "not json") if argv.include?("switches_owner")
      true
    end
    status = nil

    # "The plan says missing or unparseable reports fail the command."
    expect { status = described_class.run(runner:, specs: ["spec/models/invoice_spec.rb"]) }
      .to output(/^unreadable report: /).to_stdout

    expect(status).to eq(described_class::EX_FAILURE)
  end
end

RSpec.describe TimekeepingDemo::Regression do
  it "fails the command when the switches_owner runner returns true and its report file is empty" do
    runner = lambda do |env:, argv:|
      File.write(argv[argv.index("--out") + 1], "") if argv.include?("switches_owner")
      true
    end
    status = nil

    # "The plan says missing or unparseable reports fail the command."
    expect { status = described_class.run(runner:, specs: ["spec/models/invoice_spec.rb"]) }
      .to output(/^unreadable report: /).to_stdout

    expect(status).to eq(described_class::EX_FAILURE)
  end
end

RSpec.describe TimekeepingDemo::Regression do
  it "fails the command when the switches_owner runner returns true and its report has no examples array" do
    runner = lambda do |env:, argv:|
      File.write(argv[argv.index("--out") + 1], JSON.generate("examples" => "x")) if argv.include?("switches_owner")
      true
    end
    status = nil

    # "The plan says missing or unparseable reports fail the command."
    expect { status = described_class.run(runner:, specs: ["spec/models/invoice_spec.rb"]) }
      .to output(/^unreadable report: /).to_stdout

    expect(status).to eq(described_class::EX_FAILURE)
  end
end

RSpec.describe TimekeepingDemo::Regression do
  it "fails without raising when the switches_owner report path is a directory and the runner returns true" do
    runner = lambda do |env:, argv:|
      Dir.mkdir(argv[argv.index("--out") + 1]) if argv.include?("switches_owner")
      true
    end
    status = nil

    # "The plan says missing or unparseable reports fail the command."
    expect do
      expect { status = described_class.run(runner:, specs: ["spec/models/invoice_spec.rb"]) }
        .to output(/^unreadable report: /).to_stdout
    end.not_to raise_error

    expect(status).to eq(described_class::EX_FAILURE)
  end
end

RSpec.describe TimekeepingDemo::Regression do
  it "passes with a readable report listing one id and prints no unreadable line" do
    tagged_id = "./spec/models/invoice_spec.rb[1:9]"
    runner = lambda do |env:, argv:|
      if argv.include?("switches_owner")
        File.write(argv[argv.index("--out") + 1],
                   JSON.generate("examples" => [{ "id" => tagged_id, "status" => "passed" }]))
      end
      true
    end
    status = nil
    printed = nil

    expect { status = described_class.run(runner:, specs: ["spec/models/invoice_spec.rb"]) }
      .to output(satisfy { |out| printed = out }).to_stdout

    expect(status).to eq(described_class::EX_OK)
    expect(printed.scan(tagged_id).size).to eq(1)
    expect(printed).not_to include("unreadable report")
  end
end

RSpec.describe TimekeepingDemo::Regression do
  it "read_report tells a readable empty report apart from missing, invalid and wrongly shaped ones" do
    Dir.mktmpdir("read-report") do |dir|
      empty = File.join(dir, "empty.json")
      File.write(empty, JSON.generate("examples" => []))
      listed = File.join(dir, "listed.json")
      File.write(listed, JSON.generate("examples" => [{ "id" => "./spec/a_spec.rb[1:1]" }]))

      expect(described_class.read_report(empty)).to eq(described_class::Report.new(ids: []))
      expect(described_class.read_report(listed)).to eq(described_class::Report.new(ids: ["./spec/a_spec.rb[1:1]"]))

      invalid = File.join(dir, "invalid.json")
      File.write(invalid, "{")
      shaped = File.join(dir, "shaped.json")
      File.write(shaped, JSON.generate("examples" => nil))

      # "The plan says missing or unparseable reports fail the command."
      [File.join(dir, "missing.json"), invalid, shaped, dir].each do |path|
        result = described_class.read_report(path)
        expect(result).to be_a(described_class::UnreadableReport), "expected #{path} to be unreadable"
        expect(result.reason).to be_a(String).and(satisfy { |reason| !reason.empty? })
      end
    end
  end
end

RSpec.describe TimekeepingDemo::Regression do
  it "lists a readable report's ids exactly once and fails when the switches_owner runner returns false, without an unreadable line" do
    failed_id = "./spec/models/invoice_spec.rb[1:9]"
    runner = lambda do |env:, argv:|
      _ = env
      next true unless argv.include?("switches_owner")

      File.write(argv[argv.index("--out") + 1],
                 JSON.generate("examples" => [{ "id" => failed_id, "status" => "failed" }]))
      false
    end

    status = nil
    printed = capture_regression_output_for_failed_pass do
      status = described_class.run(runner:, states: %w[legacy], specs: ["spec/models/invoice_spec.rb"])
    end

    # A readable report is listed even when the pass failed, and the failed
    # runner result alone still fails the command.
    expect(status).to eq(described_class::EX_FAILURE)
    expect(printed.scan(failed_id).size).to eq(1)
    expect(printed).not_to include("unreadable report")
    expect(printed).not_to match(/^none$/)
  end

  def capture_regression_output_for_failed_pass
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end

RSpec.describe TimekeepingDemo::Regression do
  it "R1: a switches_owner pass whose runner returns true but writes no report fails the command and says the report is unreadable" do
    runner = ->(env:, argv:) { true }
    status = nil

    # "The plan says missing or unparseable reports fail the command. The author's declined answer and
    # run_switches_owner_report instead allow success without a readable report when the runner returns true."
    expect { status = described_class.run(runner:, specs: ["spec/models/invoice_spec.rb"]) }
      .to output(/^unreadable report: /).to_stdout

    expect(status).to eq(described_class::EX_FAILURE)
  end
end

RSpec.describe TimekeepingDemo::Regression do
  it "R1: a truncated, empty or wrongly shaped switches_owner report fails the command even when the runner returns true" do
    ['{"examples":[{"id":"./spec/models/invoice_spec.rb[1:1]"', "", "not json", '{"examples":"x"}', "[]"].each do |contents|
      runner = lambda do |env:, argv:|
        _ = env
        File.write(argv[argv.index("--out") + 1], contents) if argv.include?("switches_owner")
        true
      end
      status = nil

      # "The plan says missing or unparseable reports fail the command."
      expect { status = described_class.run(runner:, specs: ["spec/models/invoice_spec.rb"]) }
        .to output(/^unreadable report: /).to_stdout

      expect(status).to eq(described_class::EX_FAILURE), "report #{contents.inspect} was counted as a pass"
    end
  end
end

RSpec.describe TimekeepingDemo::Regression do
  it "R1: a switches_owner report path that cannot be read as a file fails the command instead of raising" do
    runner = lambda do |env:, argv:|
      _ = env
      Dir.mkdir(argv[argv.index("--out") + 1]) if argv.include?("switches_owner")
      true
    end
    status = nil

    # "The plan says missing or unparseable reports fail the command."
    expect do
      expect { status = described_class.run(runner:, specs: ["spec/models/invoice_spec.rb"]) }
        .to output(/^unreadable report: /).to_stdout
    end.not_to raise_error

    expect(status).to eq(described_class::EX_FAILURE)
  end
end

RSpec.describe TimekeepingDemo::Regression do
  it "R1: a report written by an earlier run never passes a later run whose switches_owner pass writes none" do
    write_report = true
    runner = lambda do |env:, argv:|
      _ = env
      if write_report && argv.include?("switches_owner")
        File.write(argv[argv.index("--out") + 1], JSON.generate("examples" => []))
      end
      true
    end
    first_status = nil
    second_status = nil

    expect { first_status = described_class.run(runner:, specs: ["spec/models/invoice_spec.rb"]) }.to output.to_stdout
    write_report = false
    # "The plan says missing or unparseable reports fail the command."
    expect { second_status = described_class.run(runner:, specs: ["spec/models/invoice_spec.rb"]) }
      .to output(/^unreadable report: /).to_stdout

    expect([first_status, second_status]).to eq([described_class::EX_OK, described_class::EX_FAILURE])
  end
end

RSpec.describe TimekeepingDemo::Regression do
  it "R1: read_report answers UnreadableReport for a missing file, broken JSON, a wrong shape and a directory, and Report for an empty examples list" do
    Dir.mktmpdir("read-report-adversary") do |dir|
      broken = File.join(dir, "broken.json")
      File.write(broken, '{"examples":[')
      wrong_shape = File.join(dir, "wrong_shape.json")
      File.write(wrong_shape, JSON.generate("examples" => "x"))
      directory = File.join(dir, "a_directory.json")
      Dir.mkdir(directory)
      empty = File.join(dir, "empty.json")
      File.write(empty, JSON.generate("examples" => []))

      # "The plan says missing or unparseable reports fail the command."
      [File.join(dir, "missing.json"), broken, wrong_shape, directory].each do |path|
        result = nil
        expect { result = described_class.read_report(path) }.not_to raise_error
        expect(result).to be_a(described_class::UnreadableReport), "#{File.basename(path)} was read as a report"
        expect(result.reason).to be_a(String).and(satisfy { |reason| !reason.empty? })
      end

      expect(described_class.read_report(empty)).to eq(described_class::Report.new(ids: []))
    end
  end
end

RSpec.describe TimekeepingDemo::Regression do
  it "R3: a readable switches_owner report never turns a false or nil runner result into a pass, and its ids are still listed" do
    tagged_id = "./spec/models/invoice_spec.rb[1:9]"

    [false, nil].each do |report_result|
      runner = lambda do |env:, argv:|
        _ = env
        next true unless argv.include?("switches_owner")

        File.write(argv[argv.index("--out") + 1], JSON.generate("examples" => [{ "id" => tagged_id, "status" => "passed" }]))
        report_result
      end
      status = nil

      expect { status = described_class.run(runner:, specs: ["spec/models/invoice_spec.rb"]) }
        .to output(include(tagged_id)).to_stdout
      expect(status).to eq(described_class::EX_FAILURE),
                        "a readable report passed a switches_owner run whose runner returned #{report_result.inspect}"
    end
  end
end
