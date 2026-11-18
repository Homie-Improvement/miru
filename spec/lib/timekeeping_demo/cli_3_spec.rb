# frozen_string_literal: true

require "rails_helper"
require "json"
require "tmpdir"

RSpec.describe TimekeepingDemo::CLI do
  it "exits 64 for an unknown verb and starts nothing" do
    # A double with no allowed messages fails the example if the CLI asks it to start anything.
    supervisor = double("timekeeping demo supervisor")

    Dir.mktmpdir("timekeeping-demo-state") do |state_dir|
      status = nil
      expect do
        status = described_class.run(["bogus"], root: Rails.root.to_s, supervisor:, state_dir:)
      end.to output.to_stdout_from_any_process.or(output.to_stderr_from_any_process)

      expect(status).to eq(64)
      expect(Dir.children(state_dir)).to be_empty
    end
  end
end

RSpec.describe TimekeepingDemo::CLI, "up with a recording supervisor" do
  # Records every call the CLI makes, so no process is started.
  let(:recording_supervisor_class) do
    Class.new do
      attr_reader :specs

      def initialize
        @specs = []
      end

      def method_missing(_name, *args, **_kwargs, &)
        args.flatten.each { |arg| @specs << arg if arg.is_a?(TimekeepingDemo::ProcessSpec) }
        0
      end

      def respond_to_missing?(*)
        true
      end
    end
  end

  it "up hands the supervisor only the two web apps, both relay workers and the invoice-operation worker, and writes versions.json" do
    saved = ENV.to_h.slice("TIMEKEEPING_DATABASE_URL", "DB_USER", "DATABASE_URL")
    supervisor = recording_supervisor_class.new
    Dir.mktmpdir("timekeeping-demo-state") do |state_dir|
      ENV["TIMEKEEPING_DATABASE_URL"] = "postgres://timekeeping_demo_role@127.0.0.1/timekeeping_demo"
      ENV["DB_USER"] = "monolith_demo_role"
      ENV.delete("DATABASE_URL")

      status = described_class.run(["up"], root: Rails.root.to_s, supervisor:, state_dir:)

      expect(status).to eq(0)
      # "The runtime therefore starts the monolith web app, the Timekeeping web app, the Timekeeping relay worker,
      # the monolith relay worker and the invoice-operation worker, and nothing else."
      names = supervisor.specs.map(&:name).uniq
      expect(names).to contain_exactly("monolith_web", "monolith_relay", "monolith_invoice_operations",
                                       "timekeeping_web", "timekeeping_relay")
      expect(supervisor.specs.flat_map(&:argv)).not_to include("config/solid_queue.yml")

      # "`bin/timekeeping-demo up` starts the runtime and records each application's version or artifact digest to a file."
      versions = JSON.parse(File.read(File.join(state_dir, "versions.json")))
      %w[monolith timekeeping].each do |app|
        expect(versions.fetch(app).fetch("revision")).to match(/\A\h{40}\z/)
      end
    end
  ensure
    %w[TIMEKEEPING_DATABASE_URL DB_USER DATABASE_URL].each { |key| ENV.delete(key) }
    saved&.each { |key, value| ENV[key] = value }
  end
end
