# frozen_string_literal: true

require "rails_helper"
require "json"
require "tmpdir"

# Runs the switches_owner probe in real child rspec processes through the same
# argv, environment and default runner that `bin/timekeeping-demo regression`
# uses, but on the probe alone, so it stays cheap.
RSpec.describe "timekeeping regression command", :without_transaction do
  let(:probe) { Rails.root.join("spec/fixtures/timekeeping_harness/switches_owner_probe.rb").to_s }
  let(:real_runner) { TimekeepingDemo::CLI.default_regression_runner(root: Rails.root.to_s, caller_env: ENV.to_h) }

  def run_regression(runner, spec_file = probe)
    captured = StringIO.new
    original = $stdout
    $stdout = captured
    status = TimekeepingDemo::Regression.run(runner:, states: %w[legacy], specs: [spec_file])
    [status, captured.string]
  ensure
    $stdout = original
  end

  it "a real child rspec skips the switches_owner probe example in the state run and lists it in the separate report" do
    Dir.mktmpdir("switches-owner-state-run") do |dir|
      state_out = File.join(dir, "state.json")
      # Records which examples the state child itself ran, so the proof does
      # not rest on the report alone.
      runner = lambda do |env:, argv:|
        argv += ["--format", "progress", "--format", "json", "--out", state_out] if env["TIMEKEEPING_OWNER_STATE"]
        real_runner.call(env:, argv:)
      end

      status, stdout = run_regression(runner)

      expect(status).to eq(TimekeepingDemo::CLI::EX_OK), stdout
      state_ids = JSON.parse(File.read(state_out)).fetch("examples").map { |example| example.fetch("id") }
      report_ids = stdout.scan(/\S*switches_owner_probe\.rb\[[\d:]+\]/).uniq
      # "a `:switches_owner` example is skipped by the three-state run and listed in the separate report"
      expect(state_ids.size).to eq(1)
      expect(report_ids.size).to eq(1), stdout
      expect(state_ids.map { |id| id.delete_prefix("./") }).not_to include(report_ids.first.delete_prefix("./"))
    end
  end

  it "fails a state run whose filters leave no example to run" do
    Dir.mktmpdir("switches-owner-empty-run") do |dir|
      env = { "TIMEKEEPING_OWNER_STATE" => "legacy", "TIMEKEEPING_REGRESSION" => "1",
              TimekeepingQueueLedger::PATH_KEY => File.join(dir, "queue_ledger.json") }

      expect(real_runner.call(env:, argv: [probe, "--tag", "no_example_has_this_tag"])).to be(false)
    end
  end

  it "fails a state run over a spec file that loads no rails_helper when every example is filtered out" do
    standalone = Rails.root.join("spec/fixtures/timekeeping_harness/standalone_switches_owner_probe.rb").to_s
    status, stdout = run_regression(real_runner, standalone)

    expect(stdout).to match(/^legacy: failed$/)
    expect(status).to eq(TimekeepingDemo::CLI::EX_FAILURE)
  end
end
