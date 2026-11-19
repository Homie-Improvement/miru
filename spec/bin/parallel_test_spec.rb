# frozen_string_literal: true

require "rails_helper"
require "open3"
require "tmpdir"
require "rbconfig"

RSpec.describe "bin/parallel_test" do
  context "more tests 2" do
    it "excludes each --exclude-dir path alongside the system spec directories in the parallel_rspec exclude pattern" do
      Dir.mktmpdir do |fake_bin|
        # A stand-in `bundle` records the parallel_rspec arguments instead of running the suite.
        args_file = File.join(fake_bin, "args")
        fake_bundle = File.join(fake_bin, "bundle")
        File.write(fake_bundle, "#!/bin/sh\nfor arg in \"$@\"; do echo \"$arg\"; done > #{args_file}\n")
        File.chmod(0o755, fake_bundle)
        env = {
          "PATH" => [fake_bin, File.dirname(RbConfig.ruby), "/usr/bin", "/bin"].join(File::PATH_SEPARATOR),
          "PARALLEL_RUNTIME_LOG" => File.join(fake_bin, "missing_runtime.log")
        }

        _output, status = Open3.capture2e(
          env, RbConfig.ruby, "bin/parallel_test", "-n", "2", "--exclude-system",
          "--exclude-dir", "spec/lib/timekeeping/handoff",
          chdir: Rails.root.to_s
        )

        expect(status).to be_success
        args = File.readlines(args_file, chomp: true)
        pattern_index = args.index("--exclude-pattern")
        expect(pattern_index).not_to be_nil
        expect(args.count("--exclude-pattern")).to eq(1)
        pattern = Regexp.new(args.fetch(pattern_index + 1))

        expect(pattern).to match("spec/lib/timekeeping/handoff/runner_spec.rb")
        expect(pattern).to match("spec/system/responsive/login_spec.rb")
        expect(pattern).to match("spec/system_skip/old_spec.rb")
        expect(pattern).not_to match("spec/lib/timekeeping/seed_disposition_recorder_spec.rb")
        expect(pattern).not_to match("spec/requests/api/v1/cli/entries_spec.rb")
      end
    end
  end

  context "more tests 3" do
    it "groups by runtime when the runtime log covers every spec file left after --exclude-dir" do
      Dir.mktmpdir do |fake_bin|
        args_file = File.join(fake_bin, "args")
        fake_bundle = File.join(fake_bin, "bundle")
        File.write(fake_bundle, "#!/bin/sh\nfor arg in \"$@\"; do echo \"$arg\"; done > #{args_file}\n")
        File.chmod(0o755, fake_bundle)

        # The log lists only the files that still run, so it is usable only if the
        # coverage count leaves out the excluded directory too.
        kept_specs = Dir.chdir(Rails.root) { Dir["spec/**/*_spec.rb"] }.reject do |path|
          path.start_with?("spec/system/", "spec/system_skip/", "spec/lib/timekeeping/handoff/")
        end
        runtime_log = File.join(fake_bin, "runtime.log")
        File.write(runtime_log, kept_specs.map { |path| "#{path}:1.0" }.join("\n"))

        env = { "PATH" => [fake_bin, File.dirname(RbConfig.ruby), "/usr/bin", "/bin"].join(File::PATH_SEPARATOR) }
        output, status = Open3.capture2e(
          env, RbConfig.ruby, "bin/parallel_test", "-n", "2", "--exclude-system",
          "--exclude-dir", "spec/lib/timekeeping/handoff", "--runtime-log", runtime_log,
          chdir: Rails.root.to_s
        )

        expect(status).to be_success
        args = File.readlines(args_file, chomp: true)
        group_index = args.index("--group-by")
        expect(group_index).not_to be_nil
        expect(args.fetch(group_index + 1)).to eq("runtime")
        expect(output).not_to include("Ignoring stale parallel runtime log")
      end
    end
  end

  context "more tests 4" do
    # An exclusion wider than the moved directory would silently drop specs from CI.
    it "excludes only the named directory and not a sibling path that shares its prefix" do
      Dir.mktmpdir do |dir|
        fake_bundle = File.join(dir, "bundle")
        File.write(fake_bundle, "#!/bin/sh\nexit 0\n")
        File.chmod(0o755, fake_bundle)
        env = {
          "PATH" => [dir, File.dirname(RbConfig.ruby), "/usr/bin", "/bin"].join(File::PATH_SEPARATOR),
          "PARALLEL_RUNTIME_LOG" => File.join(dir, "missing_runtime.log")
        }
        output, status = Open3.capture2e(
          env, RbConfig.ruby, "bin/parallel_test", "-n", "2", "--exclude-system",
          "--exclude-dir", "spec/lib/timekeeping/handoff",
          chdir: Rails.root.to_s
        )

        expect(status).to be_success, output
        command_line = output.lines.find { |line| line.start_with?("Command:") }
        tokens = command_line.split
        pattern = Regexp.new(tokens[tokens.index("--exclude-pattern") + 1])

        expect(pattern).to match("spec/lib/timekeeping/handoff/runner_spec.rb")
        expect(pattern).to match("spec/system/login_spec.rb")
        expect(pattern).to match("spec/system_skip/old_spec.rb")
        expect(pattern).not_to match("spec/lib/timekeeping/handoff_extra/runner_spec.rb")
        expect(pattern).not_to match("spec/lib/timekeeping/handoffs_spec.rb")
        expect(pattern).not_to match("spec/requests/api/v1/cli/sessions_spec.rb")
      end
    end
  end

  context "more tests 5" do
    # An unescaped "." would match any character and exclude directories nobody named.
    it "treats a regex metacharacter in an excluded directory as a literal character" do
      Dir.mktmpdir do |dir|
        fake_bundle = File.join(dir, "bundle")
        File.write(fake_bundle, "#!/bin/sh\nexit 0\n")
        File.chmod(0o755, fake_bundle)
        env = {
          "PATH" => [dir, File.dirname(RbConfig.ruby), "/usr/bin", "/bin"].join(File::PATH_SEPARATOR),
          "PARALLEL_RUNTIME_LOG" => File.join(dir, "missing_runtime.log")
        }
        output, status = Open3.capture2e(
          env, RbConfig.ruby, "bin/parallel_test", "-n", "2", "--exclude-system",
          "--exclude-dir", "spec/a.b",
          chdir: Rails.root.to_s
        )

        expect(status).to be_success, output
        command_line = output.lines.find { |line| line.start_with?("Command:") }
        tokens = command_line.split
        pattern = Regexp.new(tokens[tokens.index("--exclude-pattern") + 1])

        expect(pattern).to match("spec/a.b/thing_spec.rb")
        expect(pattern).not_to match("spec/aXb/thing_spec.rb")
      end
    end
  end

  context "more tests 6" do
    # If the coverage count still included the excluded files, a log written by the
    # parallel step (which never runs them) would always be rejected as stale.
    it "uses the runtime split when the log covers every spec file left after the excluded directory" do
      Dir.mktmpdir do |dir|
        fake_bundle = File.join(dir, "bundle")
        File.write(fake_bundle, "#!/bin/sh\nexit 0\n")
        File.chmod(0o755, fake_bundle)
        excluded_prefixes = ["spec/system/", "spec/system_skip/", "spec/lib/timekeeping/handoff/"]
        kept_files = Dir.chdir(Rails.root) { Dir["spec/**/*_spec.rb"] }
          .reject { |path| path.start_with?(*excluded_prefixes) }
        runtime_log = File.join(dir, "parallel_runtime_rspec.log")
        File.write(runtime_log, kept_files.map { |path| "#{path}:1.0\n" }.join)
        env = {
          "PATH" => [dir, File.dirname(RbConfig.ruby), "/usr/bin", "/bin"].join(File::PATH_SEPARATOR),
          "PARALLEL_RUNTIME_LOG" => runtime_log
        }

        output, status = Open3.capture2e(
          env, RbConfig.ruby, "bin/parallel_test", "-n", "2", "--exclude-system",
          "--exclude-dir", "spec/lib/timekeeping/handoff", "--runtime-log", runtime_log,
          chdir: Rails.root.to_s
        )

        expect(status).to be_success, output
        command_line = output.lines.find { |line| line.start_with?("Command:") }
        expect(command_line).to include("--group-by runtime")
        expect(output).not_to include("Ignoring stale parallel runtime log")
      end
    end
  end
end
