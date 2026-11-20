# frozen_string_literal: true

require "rails_helper"
require "json"
require "tmpdir"
require "fileutils"

# Builds a temporary app tree that boots Rails with the tree itself as
# Rails.root, so a dotenv file written there is read only by children started
# in the tree, never by other test processes sharing the real checkout.
module TimekeepingDotenvTree
  # Ruby resolves symlinks when it requires a file, and these files find the
  # app root from their own location, so they are real copies in the tree.
  COPIED_FILES = %w[config/application.rb config/environment.rb spec/rails_helper.rb].freeze
  COPIED_DIRS = COPIED_FILES.map { |path| File.dirname(path) }.uniq.freeze
  # Fresh directories, so the children's caches and logs stay out of the checkout.
  OWN_DIRS = %w[tmp log].freeze

  module_function

  def build(tree, dotenv:, root: Rails.root)
    root.children.each do |entry|
      name = entry.basename.to_s
      next if name.start_with?(".env") || OWN_DIRS.include?(name) || COPIED_DIRS.include?(name)

      File.symlink(entry.to_s, File.join(tree, name))
    end
    OWN_DIRS.each { |dir| Dir.mkdir(File.join(tree, dir)) }
    COPIED_DIRS.each { |dir| build_copied_dir(root.join(dir), File.join(tree, dir)) }
    File.write(File.join(tree, ".env.test.local"), dotenv)
  end

  def build_copied_dir(source, target)
    Dir.mkdir(target)
    source.children.each do |entry|
      path = File.join(target, entry.basename.to_s)
      if COPIED_FILES.include?(entry.relative_path_from(source.parent).to_s)
        FileUtils.cp(entry.to_s, path)
      else
        File.symlink(entry.to_s, path)
      end
    end
  end
end

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
        argv += ["--format", "progress", "--format", "json", "--out", state_out] unless env["TIMEKEEPING_OWNER_STATE"] == ""
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

RSpec.describe "timekeeping regression command", :without_transaction do
  it "a dotenv file naming an owner state is loaded at boot but neither restores a state in the switches_owner report pass nor overrides the legacy state pass" do
    checkout_env_files_before = Rails.root.glob(".env*").map(&:to_s).sort

    Dir.mktmpdir("dotenv-owner-state-tree") do |tree|
      TimekeepingDotenvTree.build(tree, dotenv: "TIMEKEEPING_OWNER_STATE=timekeeping\nTIMEKEEPING_DOTENV_PROBE=loaded\n")

      runner = TimekeepingDemo::CLI.default_regression_runner(
        root: tree, caller_env: ENV.to_h.merge("TIMEKEEPING_DOTENV_TREE" => File.realpath(tree))
      )
      probe = File.join(tree, "spec/fixtures/timekeeping_harness/dotenv_owner_state_probe.rb")

      captured = StringIO.new
      original = $stdout
      status = nil
      begin
        $stdout = captured
        status = TimekeepingDemo::Regression.run(runner:, states: %w[legacy], specs: [probe])
      ensure
        $stdout = original
      end
      stdout = captured.string

      # "Prevent file-based configuration from restoring owner selection, and test boot with a temporary dotenv file."
      # The probe's examples assert inside each child that the dotenv file was read, that Rails.root is this tree,
      # that the report pass selects no state and keeps its rollback row, and that the state pass selects legacy.
      expect(status).to eq(TimekeepingDemo::CLI::EX_OK), stdout
      expect(stdout).to match(/^legacy: passed$/)
      expect(stdout.scan(/\S*dotenv_owner_state_probe\.rb\[[\d:]+\]/).uniq.size).to eq(1), stdout
    end

    # The temporary dotenv file lives only in the tree, never in the shared checkout.
    expect(Rails.root.glob(".env*").map(&:to_s).sort).to eq(checkout_env_files_before)
  end
end

RSpec.describe "timekeeping regression command", :without_transaction do
  it "a regression child with an empty TIMEKEEPING_OWNER_STATE boots with no state and does not fail when its filters leave no example" do
    probe = Rails.root.join("spec/fixtures/timekeeping_harness/switches_owner_probe.rb").to_s
    runner = TimekeepingDemo::CLI.default_regression_runner(root: Rails.root.to_s, caller_env: ENV.to_h)

    Dir.mktmpdir("switches-owner-empty-marker") do |dir|
      env = { "TIMEKEEPING_OWNER_STATE" => "", "TIMEKEEPING_REGRESSION" => "1",
              TimekeepingQueueLedger::PATH_KEY => File.join(dir, "queue_ledger.json") }

      # The empty marker means "no owner state": the harness must not reject it at load, and the
      # fail-if-no-examples switch for state runs must stay off, because finding no tagged example
      # is a normal outcome of the report pass.
      expect(runner.call(env:, argv: [probe, "--tag", "no_example_has_this_tag"])).to be(true)
    end
  end
end

RSpec.describe "timekeeping regression command", :without_transaction do
  it "a dotenv file in the app root naming an owner state is loaded but does not restore owner selection in the switches_owner report pass, and the legacy state pass keeps legacy" do
    probe_source = <<~RUBY
      # frozen_string_literal: true

      require "rails_helper"

      RSpec.describe "dotenv owner state boot probe", order: :defined do
        it "state pass sees the dotenv file and keeps the state it was given" do
          expect(ENV.fetch("TIMEKEEPING_DOTENV_PROBE", nil)).to eq("loaded")
          expect(Rails.root.to_s).to start_with(ENV.fetch("TIMEKEEPING_DOTENV_TREE"))
          expect(TimekeepingOwnerState::SELECTED).to eq("legacy")
        end

        context "in the report pass", :switches_owner do
          before(:all) { TimekeepingOwnerState.apply!("rollback") }

          after(:all) do
            TimekeepingOwnership.delete_all
            TimekeepingOwnership.ensure_initial!
          end

          it "report pass sees the dotenv file but no selected owner state" do
            expect(ENV.fetch("TIMEKEEPING_DOTENV_PROBE", nil)).to eq("loaded")
            expect(Rails.root.to_s).to start_with(ENV.fetch("TIMEKEEPING_DOTENV_TREE"))
            expect(TimekeepingOwnerState::SELECTED).to be_nil
            expect_owner_state!("rollback")
          end
        end
      end
    RUBY

    Dir.mktmpdir("dotenv-owner-state-tree") do |tree|
      # The children run in their own app tree so the dotenv file is never
      # visible to other test processes using the real checkout.
      TimekeepingDotenvTree.build(tree, dotenv: "TIMEKEEPING_OWNER_STATE=timekeeping\nTIMEKEEPING_DOTENV_PROBE=loaded\n")
      probe = File.join(tree, "dotenv_owner_state_boot_probe.rb")
      File.write(probe, probe_source)

      caller_env = ENV.to_h.merge("TIMEKEEPING_DOTENV_TREE" => File.realpath(tree))
      runner = TimekeepingDemo::CLI.default_regression_runner(root: tree, caller_env:)

      captured = StringIO.new
      original = $stdout
      status = nil
      begin
        $stdout = captured
        status = TimekeepingDemo::Regression.run(runner:, states: %w[legacy], specs: [probe])
      ensure
        $stdout = original
      end

      # "Prevent file-based configuration from restoring owner selection, and test boot with a temporary dotenv file."
      expect(captured.string).to match(/^legacy: passed$/)
      expect(captured.string).to match(/dotenv_owner_state_boot_probe\.rb\[1:2:1\]/)
      expect(status).to eq(TimekeepingDemo::CLI::EX_OK), captured.string
    end

    expect(Rails.root.children.map { |entry| entry.basename.to_s }).not_to include("dotenv_owner_state_boot_probe.rb")
  end
end

RSpec.describe "timekeeping regression command", :without_transaction do
  it "a regression child given an empty TIMEKEEPING_OWNER_STATE boots with no state and passes when its filters match no example" do
    probe = Rails.root.join("spec/fixtures/timekeeping_harness/switches_owner_probe.rb").to_s
    real_runner = TimekeepingDemo::CLI.default_regression_runner(root: Rails.root.to_s, caller_env: ENV.to_h)

    Dir.mktmpdir("switches-owner-empty-marker-run") do |dir|
      env = { "TIMEKEEPING_OWNER_STATE" => "", "TIMEKEEPING_REGRESSION" => "1",
              TimekeepingQueueLedger::PATH_KEY => File.join(dir, "queue_ledger.json") }

      # The report pass marks itself with "": finding no tagged example is a
      # normal outcome for it, so the empty marker must count as no state both
      # before boot (fail_if_no_examples) and after it (no load-time error).
      expect(real_runner.call(env:, argv: [probe, "--tag", "no_example_has_this_tag"])).to be(true)
    end
  end
end

RSpec.describe "timekeeping regression command", :without_transaction do
  it "a dotenv file naming the timekeeping state neither restores a state in the switches_owner pass nor overrides the legacy pass" do
    checkout_env_files_before = Dir.glob(Rails.root.join(".env*").to_s, File::FNM_DOTMATCH).sort
    Dir.mktmpdir("dotenv-owner-state-tree") do |tree|
      TimekeepingDotenvTree.build(tree, dotenv: "TIMEKEEPING_OWNER_STATE=timekeeping\nTIMEKEEPING_DOTENV_PROBE=loaded\n")
      probe = File.join(tree, "spec/fixtures/timekeeping_harness/dotenv_owner_state_probe.rb")
      expect(File).to exist(probe)

      caller_env = ENV.to_h.merge("TIMEKEEPING_DOTENV_TREE" => File.realpath(tree))
      runner = TimekeepingDemo::CLI.default_regression_runner(root: tree, caller_env:)

      captured = StringIO.new
      original = $stdout
      begin
        $stdout = captured
        status = TimekeepingDemo::Regression.run(runner:, states: %w[legacy], specs: [probe])
      ensure
        $stdout = original
      end

      # "Prevent file-based configuration from restoring owner selection, and test boot with a temporary dotenv file."
      # The probe fails the switches_owner pass if the dotenv value is selected or rewrites the row, and fails the
      # legacy pass if the dotenv value overrides the state the command gave it.
      expect(captured.string).to match(/^legacy: passed$/)
      expect(captured.string).to match(/dotenv_owner_state_probe\.rb\[[\d:]+\]/)
      expect(status).to eq(TimekeepingDemo::CLI::EX_OK), captured.string
    end
    # The test's dotenv file never reaches the shared checkout, where concurrent test processes would read it.
    expect(Dir.glob(Rails.root.join(".env*").to_s, File::FNM_DOTMATCH).sort).to eq(checkout_env_files_before)
  end
end

RSpec.describe "timekeeping regression command", :without_transaction do
  it "a dotenv file holding an unknown owner state does not crash the switches_owner pass at load" do
    Dir.mktmpdir("dotenv-owner-state-tree") do |tree|
      TimekeepingDotenvTree.build(tree, dotenv: "TIMEKEEPING_OWNER_STATE=bogus\nTIMEKEEPING_DOTENV_PROBE=loaded\n")
      probe = File.join(tree, "spec/fixtures/timekeeping_harness/dotenv_owner_state_probe.rb")
      expect(File).to exist(probe)

      caller_env = ENV.to_h.merge("TIMEKEEPING_DOTENV_TREE" => File.realpath(tree))
      runner = TimekeepingDemo::CLI.default_regression_runner(root: tree, caller_env:)

      captured = StringIO.new
      original = $stdout
      begin
        $stdout = captured
        status = TimekeepingDemo::Regression.run(runner:, states: %w[legacy], specs: [probe])
      ensure
        $stdout = original
      end

      # "Prevent file-based configuration from restoring owner selection, and test boot with a temporary dotenv file."
      # A dotenv value that is not a state must not reach the harness's load-time check in either pass, so the run
      # neither picks up a state nor fails at load because of the file.
      expect(captured.string).to match(/^legacy: passed$/)
      expect(captured.string).to match(/dotenv_owner_state_probe\.rb\[[\d:]+\]/)
      expect(status).to eq(TimekeepingDemo::CLI::EX_OK), captured.string
    end
  end
end
