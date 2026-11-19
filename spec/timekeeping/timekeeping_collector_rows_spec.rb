# frozen_string_literal: true

require "rails_helper"
require "open3"
require "tmpdir"

# The probe writes invoice_operations rows into the Timekeeping database on
# purpose. It runs in its own rspec process with a private ledger path, so a
# suite ledger active in this run never records those rows as a stray
# worker's executions. :without_transaction keeps this process from holding
# row locks that the child's suite-start truncate would wait on.
RSpec.describe "Timekeeping collector real-row examples", :without_transaction do
  # "A database-backed spec creates completed, claimed and failed Timekeeping Solid Queue jobs, calls
  # TimekeepingCollector.collect, and asserts their identities and kinds, with invoice_operations collected and
  # timekeeping_relay ignored."
  it "the Timekeeping collector row probe passes every example in its own run with a private ledger and skips none" do
    skip "set TIMEKEEPING_LIVE=1 to use the Timekeeping test database" unless ENV["TIMEKEEPING_LIVE"] == "1"

    probe = Rails.root.join("spec/fixtures/timekeeping_harness/timekeeping_collector_rows_probe.rb")
    expect(probe).to exist
    expect(probe.basename.to_s).not_to end_with("_spec.rb")

    Dir.mktmpdir("timekeeping-collector-rows") do |dir|
      ledger_path = File.join(dir, "collector_rows_ledger.json")
      stdout, stderr, status = Open3.capture3(
        { TimekeepingQueueLedger::PATH_KEY => ledger_path },
        "bundle", "exec", "rspec", probe.to_s, chdir: Rails.root.to_s
      )

      expect(status).to be_success, "#{stdout}\n#{stderr}"
      summary = stdout[/(\d+) examples?, 0 failures(.*)$/]
      expect(summary).not_to be_nil, stdout
      expect(Integer(Regexp.last_match(1), 10)).to be >= 1
      expect(summary).not_to include("pending")
    end
  end
end
