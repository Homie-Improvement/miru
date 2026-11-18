# frozen_string_literal: true

require "rails_helper"
require "json"
require "open3"
require "tmpdir"

RSpec.describe TimekeepingDemo::CLI do
  it "writes a versions file that holds no generated credential" do
    started = []
    supervisor = instance_double(TimekeepingDemo::Supervisor)
    allow(supervisor).to receive(:prepare) { |*_args, **_kwargs| true }
    allow(supervisor).to receive(:run) do |specs, *_rest, **_kwargs|
      started.concat(specs)
      0
    end

    Dir.mktmpdir do |state_dir|
      env = {
        "DB_USER" => "monolith_user",
        "TIMEKEEPING_DATABASE_URL" => "postgres://timekeeping_user:tk_db_secret@127.0.0.1:5432/timekeeping_development"
      }
      original = env.keys.index_with { |key| ENV.fetch(key, nil) }
      begin
        env.each { |key, value| ENV[key] = value }
        described_class.run(["up"], root: Rails.root.to_s, supervisor:, state_dir:)
      ensure
        original.each { |key, value| ENV[key] = value }
      end

      # "`bin/timekeeping-demo up` starts the runtime and records each application's version or artifact digest to a file."
      versions_text = File.read(File.join(state_dir, "versions.json"))
      versions = JSON.parse(versions_text)
      expect(versions).to include("monolith", "timekeeping")

      # "No credential is written to a checked-in file."
      expect(versions_text).not_to include("PRIVATE KEY")
      expect(versions_text).not_to include("tk_db_secret")
      secrets = started.flat_map { |spec| spec.env.values_at(*%w[TIMEKEEPING_SERVICE_TOKEN TIMEKEEPING_TOKEN_PRIVATE_KEY]) }.compact
      expect(secrets).not_to be_empty
      secrets.reject(&:empty?).each { |secret| expect(versions_text).not_to include(secret) }
    end
  end

  it "up writes versions.json for both applications, replaces it on a second run, and keeps credentials out of it" do
    governed_keys = %w[TIMEKEEPING_DATABASE_URL DATABASE_URL DB_USER DB_PASS]
    saved = governed_keys.index_with { |key| ENV.fetch(key, nil) }
    root = Rails.root.to_s
    head, status = Open3.capture2("git", "-C", root, "rev-parse", "HEAD")
    skip "the checkout is not a git work tree" unless status.success?

    begin
      # Different database users on each side, so the launcher's shared-credential refusal does not apply.
      ENV["TIMEKEEPING_DATABASE_URL"] = "postgres://timekeeping_demo_user@127.0.0.1:5432/timekeeping_demo"
      ENV["DATABASE_URL"] = "postgres://monolith_demo_user@127.0.0.1:5432/miru_demo"
      ENV.delete("DB_USER")
      ENV.delete("DB_PASS")

      Dir.mktmpdir("timekeeping-demo-state") do |state_dir|
        versions_path = File.join(state_dir, "versions.json")

        # "`bin/timekeeping-demo up` starts the runtime and records each application's version or artifact digest to a file."
        expect(described_class.run(["up"], root:, supervisor: spy("supervisor"), state_dir:)).to eq(0)
        first_text = File.read(versions_path)
        first = JSON.parse(first_text)
        expect(first.dig("monolith", "revision")).to eq(head.strip)
        expect(first.dig("timekeeping", "revision")).to eq(head.strip)
        expect(first.dig("timekeeping", "tree")).to match(/\A\h{40}\z/)

        # A second run replaces the record rather than appending to it, so the file stays one JSON document.
        expect(described_class.run(["up"], root:, supervisor: spy("supervisor"), state_dir:)).to eq(0)
        second_text = File.read(versions_path)
        expect { JSON.parse(second_text) }.not_to raise_error
        expect(JSON.parse(second_text).keys).to include("monolith", "timekeeping")

        # "No credential is written to a checked-in file."
        [first_text, second_text].each do |text|
          expect(text).not_to include("PRIVATE KEY")
          expect(text).not_to include("PUBLIC KEY")
          expect(text).not_to include("timekeeping_demo_user")
          expect(text).not_to include("monolith_demo_user")
          expect(text).not_to match(/TOKEN|_KEY|_URL/)
        end
      end
    ensure
      saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
  end

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
