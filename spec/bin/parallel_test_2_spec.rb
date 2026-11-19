require "rails_helper"
require "open3"
require "tmpdir"
require "rbconfig"

RSpec.describe "bin/parallel_test" do
  # Every parallel process would inherit one explicit ledger path, so one suite-start delete would remove the others' ledgers.
  it "refuses to start when TIMEKEEPING_QUEUE_LEDGER_PATH would be shared by every process" do
    Dir.mktmpdir do |fake_bin|
      args_file = File.join(fake_bin, "args")
      fake_bundle = File.join(fake_bin, "bundle")
      File.write(fake_bundle, "#!/bin/sh\nfor arg in \"$@\"; do echo \"$arg\"; done > #{args_file}\n")
      File.chmod(0o755, fake_bundle)
      base_env = {
        "PATH" => [fake_bin, File.dirname(RbConfig.ruby), "/usr/bin", "/bin"].join(File::PATH_SEPARATOR),
        "PARALLEL_RUNTIME_LOG" => File.join(fake_bin, "missing_runtime.log")
      }

      refused_env = base_env.merge("TIMEKEEPING_QUEUE_LEDGER_PATH" => File.join(fake_bin, "shared.json"))
      output, status = Open3.capture2e(refused_env, RbConfig.ruby, "bin/parallel_test", "-n", "2",
                                       chdir: Rails.root.to_s)

      expect(status).not_to be_success
      expect(output).to include("TIMEKEEPING_QUEUE_LEDGER_PATH")
      expect(File.exist?(args_file)).to be(false)

      [nil, "", "  "].each do |blank|
        allowed_env = base_env.merge("TIMEKEEPING_QUEUE_LEDGER_PATH" => blank)
        output, status = Open3.capture2e(allowed_env, RbConfig.ruby, "bin/parallel_test", "-n", "2",
                                         chdir: Rails.root.to_s)

        expect(status).to be_success, output
        expect(File.readlines(args_file, chomp: true)).to include("parallel_rspec")
        File.delete(args_file)
      end
    end
  end
end
