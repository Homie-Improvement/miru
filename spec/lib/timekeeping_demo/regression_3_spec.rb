# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require "json"

RSpec.describe TimekeepingDemo::Regression do
  context "more tests 2" do
    it "each child env carries its own owner state, REGRESSION and LIVE set to 1, and a distinct temp ledger path" do
      calls = []
      runner = lambda do |env:, argv:|
        calls << { env: env.dup, argv: argv.dup }
        true
      end
      caller_ledger = File.join(Dir.tmpdir, "caller_ledger.json")
      saved = ENV.to_h.slice("TIMEKEEPING_OWNER_STATE", "TIMEKEEPING_QUEUE_LEDGER_PATH")
      begin
        ENV["TIMEKEEPING_OWNER_STATE"] = "rollback"
        ENV["TIMEKEEPING_QUEUE_LEDGER_PATH"] = caller_ledger
        expect { described_class.run(runner:, specs: ["spec/models/invoice_spec.rb"]) }.to output.to_stdout
      ensure
        %w[TIMEKEEPING_OWNER_STATE TIMEKEEPING_QUEUE_LEDGER_PATH].each { |key| ENV[key] = saved[key] }
      end

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
      expect(ledger_paths).not_to include(caller_ledger)
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
      saved = ENV.fetch("TIMEKEEPING_OWNER_STATE", nil)
      begin
        ENV["TIMEKEEPING_OWNER_STATE"] = "timekeeping"
        # "Run one more pass with `--tag switches_owner --format json --out <tmp file>` and no owner state; print the example ids from that file under a separate heading, or \"none\". A failure in that pass also returns `EX_FAILURE`"
        expect { status = described_class.run(runner:, specs: ["spec/models/invoice_spec.rb"]) }
          .to output(%r{switches_owner.*\./spec/models/invoice_spec\.rb\[1:4\].*\./spec/models/invoice_spec\.rb\[1:7\]}m).to_stdout
      ensure
        ENV["TIMEKEEPING_OWNER_STATE"] = saved
      end

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
