# frozen_string_literal: true

require "rails_helper"
require "open3"
require "tmpdir"
require "rbconfig"

RSpec.describe "bin/parallel_test" do
  # Runs bin/parallel_test with a stand-in `bundle` on PATH that records the
  # parallel_rspec arguments instead of running the suite. Returns the script's
  # output, its exit status and the recorded arguments.
  def run_parallel_test_with_fake_bundle(*args, runtime_log: nil)
    Dir.mktmpdir do |fake_bin|
      args_file = File.join(fake_bin, "args")
      fake_bundle = File.join(fake_bin, "bundle")
      File.write(fake_bundle, "#!/bin/sh\nfor arg in \"$@\"; do echo \"$arg\"; done > #{args_file}\n")
      File.chmod(0o755, fake_bundle)
      env = {
        "PATH" => [fake_bin, File.dirname(RbConfig.ruby), "/usr/bin", "/bin"].join(File::PATH_SEPARATOR),
        "PARALLEL_RUNTIME_LOG" => runtime_log || File.join(fake_bin, "missing_runtime.log")
      }

      output, status = Open3.capture2e(env, RbConfig.ruby, "bin/parallel_test", *args, chdir: Rails.root.to_s)
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
