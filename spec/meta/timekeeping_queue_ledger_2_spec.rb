# frozen_string_literal: true

require "rails_helper"
require "open3"
require "tmpdir"

RSpec.describe "Timekeeping queue ledger probe isolation" do
  # "Every probe subprocess sets it to its own temporary file, so a probe never touches the parent run's ledger."
  it "a clean probe run leaves the parent's inherited ledger file byte for byte unchanged" do
    skip "set TIMEKEEPING_LIVE=1 to run the queue ledger probes" unless ENV["TIMEKEEPING_LIVE"] == "1"

    Dir.mktmpdir("queue-ledger-parent") do |dir|
      parent_path = File.join(dir, "parent_ledger.json")
      child_path = File.join(dir, "child_ledger.json")
      violation = JSON.generate(
        "records" => [{ "database" => "monolith", "queue" => "default", "job_class" => "StrayJob",
                        "kind" => "completed", "job_id" => 1, "active_job_id" => "parent-violation",
                        "execution_id" => nil, "created_at" => "2026-01-01T00:00:00Z",
                        "finished_at" => "2026-01-01T00:00:01Z" }],
        "controls" => []
      )
      File.write(parent_path, violation)
      previous = ENV.fetch("TIMEKEEPING_QUEUE_LEDGER_PATH", nil)
      begin
        ENV["TIMEKEEPING_QUEUE_LEDGER_PATH"] = parent_path
        probe = Rails.root.join("spec/fixtures/timekeeping_harness/queue_ledger_probe.rb").to_s
        stdout, stderr, status = Open3.capture3(
          { "QUEUE_LEDGER_PROBE" => "clean", "TIMEKEEPING_QUEUE_LEDGER_PATH" => child_path },
          "bundle", "exec", "rspec", probe, chdir: Rails.root.to_s
        )
      ensure
        ENV["TIMEKEEPING_QUEUE_LEDGER_PATH"] = previous
      end

      expect(status).to be_success, "#{stdout}\n#{stderr}"
      expect(File.binread(parent_path)).to eq(violation.b)
      expect(File.exist?(child_path)).to be(true)
    end
  end
end
