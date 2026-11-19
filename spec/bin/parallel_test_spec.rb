# frozen_string_literal: true

require "rails_helper"
require "open3"
require "tmpdir"
require "rbconfig"

RSpec.describe "bin/parallel_test" do
  # Runs bin/parallel_test with a stand-in `bundle` on PATH that records the
  # parallel_rspec arguments instead of running the suite. Returns the script's
  # output, its exit status and the recorded arguments. The queue ledger
  # override is unset by default because the script refuses to run with one,
  # and an override left in this process's ENV would otherwise leak in.
  def run_parallel_test_with_fake_bundle(*args, runtime_log: nil, env: { "TIMEKEEPING_QUEUE_LEDGER_PATH" => nil })
    Dir.mktmpdir do |fake_bin|
      args_file = File.join(fake_bin, "args")
      fake_bundle = File.join(fake_bin, "bundle")
      File.write(fake_bundle, "#!/bin/sh\nfor arg in \"$@\"; do echo \"$arg\"; done > #{args_file}\n")
      File.chmod(0o755, fake_bundle)
      run_env = {
        "PATH" => [fake_bin, File.dirname(RbConfig.ruby), "/usr/bin", "/bin"].join(File::PATH_SEPARATOR),
        "PARALLEL_RUNTIME_LOG" => runtime_log || File.join(fake_bin, "missing_runtime.log")
      }.merge(env)

      output, status = Open3.capture2e(run_env, RbConfig.ruby, "bin/parallel_test", *args, chdir: Rails.root.to_s)
      recorded_args = File.exist?(args_file) ? File.readlines(args_file, chomp: true) : []
      [output, status, recorded_args]
    end
  end

  def exclude_pattern_from(recorded_args)
    expect(recorded_args.count("--exclude-pattern")).to eq(1)
    Regexp.new(recorded_args.fetch(recorded_args.index("--exclude-pattern") + 1))
  end

  # An exclusion wider than the moved directory would silently drop specs from CI.
  it "excludes each --exclude-dir path alongside the system spec directories, and nothing that shares its prefix" do
    output, status, recorded_args = run_parallel_test_with_fake_bundle(
      "-n", "2", "--exclude-system", "--exclude-dir", "spec/lib/timekeeping/handoff"
    )

    expect(status).to be_success, output
    pattern = exclude_pattern_from(recorded_args)

    expect(pattern).to match("spec/lib/timekeeping/handoff/runner_spec.rb")
    expect(pattern).to match("spec/system/responsive/login_spec.rb")
    expect(pattern).to match("spec/system/login_spec.rb")
    expect(pattern).to match("spec/system_skip/old_spec.rb")
    expect(pattern).not_to match("spec/lib/timekeeping/handoff_extra/runner_spec.rb")
    expect(pattern).not_to match("spec/lib/timekeeping/handoffs_spec.rb")
    expect(pattern).not_to match("spec/lib/timekeeping/seed_disposition_recorder_spec.rb")
    expect(pattern).not_to match("spec/requests/api/v1/cli/entries_spec.rb")
    expect(pattern).not_to match("spec/requests/api/v1/cli/sessions_spec.rb")

    # The printed command carries the same pattern the script hands to parallel_rspec.
    tokens = output.lines.find { |line| line.start_with?("Command:") }.split
    expect(tokens[tokens.index("--exclude-pattern") + 1]).to eq(pattern.source)
  end

  # A plain run is what developers use locally, so it must keep excluding only the system specs.
  it "excludes only the system spec directories when no --exclude-dir is given" do
    output, status, recorded_args = run_parallel_test_with_fake_bundle("-n", "2")

    expect(status).to be_success, output
    expect(recorded_args).to include("spec")
    pattern = exclude_pattern_from(recorded_args)

    expect(pattern).to match("spec/system/x_spec.rb")
    expect(pattern).to match("spec/system_skip/x_spec.rb")
    expect(pattern).not_to match("spec/lib/timekeeping/handoff/x_spec.rb")
    expect(pattern).not_to match("spec/models/x_spec.rb")
  end

  # With nothing to exclude, an empty pattern would match every path and run no specs.
  it "passes no exclude pattern when system specs are included and no --exclude-dir is given" do
    output, status, recorded_args = run_parallel_test_with_fake_bundle("-n", "2", "-i")

    expect(status).to be_success, output
    expect(recorded_args).to include("spec")
    expect(recorded_args).not_to include("--exclude-pattern")
  end

  # Explicit paths run as given, so an --exclude-dir beside them would be ignored without a word.
  it "refuses --exclude-dir together with explicit spec paths, and runs nothing" do
    output, status, recorded_args = run_parallel_test_with_fake_bundle(
      "-n", "2", "--exclude-dir", "spec/lib/timekeeping/handoff", "spec/lib"
    )

    expect(status).not_to be_success
    expect(output).to include("--exclude-dir only applies when no spec paths are given")
    expect(recorded_args).to be_empty
  end

  # An unescaped "." would match any character and exclude directories nobody named.
  it "treats a regex metacharacter in an excluded directory as a literal character" do
    output, status, recorded_args = run_parallel_test_with_fake_bundle(
      "-n", "2", "--exclude-system", "--exclude-dir", "spec/a.b"
    )

    expect(status).to be_success, output
    pattern = exclude_pattern_from(recorded_args)

    expect(pattern).to match("spec/a.b/thing_spec.rb")
    expect(pattern).not_to match("spec/aXb/thing_spec.rb")
  end

  # If the coverage count still included the excluded files, a log written by the
  # parallel step (which never runs them) would always be rejected as stale.
  it "groups by runtime when the runtime log covers every spec file left after --exclude-dir" do
    Dir.mktmpdir do |log_dir|
      excluded_prefixes = ["spec/system/", "spec/system_skip/", "spec/lib/timekeeping/handoff/"]
      kept_specs = Dir.chdir(Rails.root) { Dir["spec/**/*_spec.rb"] }
        .reject { |path| path.start_with?(*excluded_prefixes) }
      runtime_log = File.join(log_dir, "parallel_runtime_rspec.log")
      File.write(runtime_log, kept_specs.map { |path| "#{path}:1.0\n" }.join)

      output, status, recorded_args = run_parallel_test_with_fake_bundle(
        "-n", "2", "--exclude-system", "--exclude-dir", "spec/lib/timekeeping/handoff",
        "--runtime-log", runtime_log, runtime_log: runtime_log
      )

      expect(status).to be_success, output
      group_index = recorded_args.index("--group-by")
      expect(group_index).not_to be_nil
      expect(recorded_args.fetch(group_index + 1)).to eq("runtime")
      expect(output.lines.find { |line| line.start_with?("Command:") }).to include("--group-by runtime")
      expect(output).not_to include("Ignoring stale parallel runtime log")
    end
  end
end

require "rails_helper"
require "open3"
require "tmpdir"
require "rbconfig"

RSpec.describe "bin/parallel_test" do
  # "Under bin/parallel_test each process resolves its own ledger path, so one process's suite-start delete cannot remove another process's ledger file."
  it "bin/parallel_test refuses to start when one TIMEKEEPING_QUEUE_LEDGER_PATH would be shared by every process" do
    Dir.mktmpdir do |fake_bin|
      args_file = File.join(fake_bin, "args")
      fake_bundle = File.join(fake_bin, "bundle")
      File.write(fake_bundle, "#!/bin/sh\nfor arg in \"$@\"; do echo \"$arg\"; done > #{args_file}\n")
      File.chmod(0o755, fake_bundle)
      env = {
        "PATH" => [fake_bin, File.dirname(RbConfig.ruby), "/usr/bin", "/bin"].join(File::PATH_SEPARATOR),
        "PARALLEL_RUNTIME_LOG" => File.join(fake_bin, "missing_runtime.log"),
        "TIMEKEEPING_QUEUE_LEDGER_PATH" => File.join(fake_bin, "shared_ledger.json")
      }

      output, status = Open3.capture2e(env, RbConfig.ruby, "bin/parallel_test", "-n", "2", chdir: Rails.root.to_s)

      expect(status).not_to be_success, output
      expect(output).to include("TIMEKEEPING_QUEUE_LEDGER_PATH")
      expect(File.exist?(args_file)).to be(false)
    end
  end
end

require "rails_helper"
require "open3"
require "tmpdir"
require "rbconfig"

RSpec.describe "bin/parallel_test" do
  # One inherited override would give every parallel process the same ledger file, so one suite-start delete could remove another's.
  it "refuses to start when TIMEKEEPING_QUEUE_LEDGER_PATH would be shared by every process" do
    Dir.mktmpdir do |fake_bin|
      args_file = File.join(fake_bin, "args")
      fake_bundle = File.join(fake_bin, "bundle")
      File.write(fake_bundle, "#!/bin/sh\nfor arg in \"$@\"; do echo \"$arg\"; done > #{args_file}\n")
      File.chmod(0o755, fake_bundle)
      env = {
        "PATH" => [fake_bin, File.dirname(RbConfig.ruby), "/usr/bin", "/bin"].join(File::PATH_SEPARATOR),
        "PARALLEL_RUNTIME_LOG" => File.join(fake_bin, "missing_runtime.log"),
        "TIMEKEEPING_QUEUE_LEDGER_PATH" => File.join(fake_bin, "shared_ledger.json")
      }

      output, status = Open3.capture2e(env, RbConfig.ruby, "bin/parallel_test", "-n", "2", chdir: Rails.root.to_s)

      expect(status).not_to be_success
      expect(output).to include("TIMEKEEPING_QUEUE_LEDGER_PATH")
      expect(File.exist?(args_file)).to be(false)
    end
  end
end

require "rails_helper"
require "open3"
require "tmpdir"
require "rbconfig"

RSpec.describe "bin/parallel_test" do
  # One override inherited by every process would make them all share one
  # ledger file, so one process's suite-start delete would remove the others'.
  # Acceptance: "Under bin/parallel_test each process resolves its own ledger path, so one process's suite-start delete cannot remove another process's ledger file."
  it "refuses an inherited TIMEKEEPING_QUEUE_LEDGER_PATH that every parallel process would share, and starts nothing" do
    Dir.mktmpdir do |fake_bin|
      args_file = File.join(fake_bin, "args")
      fake_bundle = File.join(fake_bin, "bundle")
      File.write(fake_bundle, "#!/bin/sh\nfor arg in \"$@\"; do echo \"$arg\"; done > #{args_file}\n")
      File.chmod(0o755, fake_bundle)
      env = {
        "PATH" => [fake_bin, File.dirname(RbConfig.ruby), "/usr/bin", "/bin"].join(File::PATH_SEPARATOR),
        "PARALLEL_RUNTIME_LOG" => File.join(fake_bin, "missing_runtime.log"),
        "TIMEKEEPING_QUEUE_LEDGER_PATH" => File.join(fake_bin, "shared_ledger.json")
      }

      output, status = Open3.capture2e(env, RbConfig.ruby, "bin/parallel_test", "-n", "2", chdir: Rails.root.to_s)

      expect(status).not_to be_success
      expect(output).to include("TIMEKEEPING_QUEUE_LEDGER_PATH")
      expect(File.exist?(args_file)).to be(false)
    end
  end
end
