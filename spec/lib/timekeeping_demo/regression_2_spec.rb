# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "tmpdir"

RSpec.describe TimekeepingDemo::Regression do
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
end
