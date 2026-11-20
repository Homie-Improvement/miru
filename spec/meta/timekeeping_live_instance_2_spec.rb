# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimekeepingLiveInstance do
  context "more tests 2", "database_url keyword" do
    # "with `database_url:` given, the db:prepare child env carries only that URL even when global ENV names another"
    it "db:prepare child env carries only the database_url keyword value when global ENV names another URL" do
      global_url = "postgresql://global_user@127.0.0.1/timekeeping_global_live_test"
      given_url = "postgresql://given_user@127.0.0.1/timekeeping_given_live_test"
      commands = []
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture2e) do |*args, **_options|
        commands << args
        ["", status]
      end
      allow(Process).to receive(:spawn).and_return(4242)
      allow(Process).to receive(:wait).and_return(nil)
      allow(Process).to receive(:kill)
      WebMock.disable_net_connect!(allow_localhost: true)
      stub_request(:get, %r{/internal/v1/metrics\z}).to_return(status: 200)
      previous_url = ENV.fetch("TIMEKEEPING_DATABASE_URL", nil)
      ENV["TIMEKEEPING_DATABASE_URL"] = global_url
      instance = nil
      begin
        instance = described_class.start(reference_stub: TimekeepingLiveInstance::ReferenceStub.new, database_url: given_url)
      ensure
        ENV["TIMEKEEPING_DATABASE_URL"] = previous_url
        instance&.stop
      end

      prepare = commands.find { |args| args.include?("db:prepare") }
      expect(prepare).not_to be_nil
      env = prepare.first
      expect(env.fetch("TIMEKEEPING_DATABASE_URL")).to eq(given_url)
      expect(env.values.compact.map(&:to_s)).not_to include(global_url)
      expect(env.fetch("DATABASE_URL")).to be_nil
    end
  end

  context "more tests 3", "admission_generation keyword" do
    # "`TimekeepingLiveInstance.start(reference_stub:, admission_generation: 2)` admits generation 2 and `write_entry` sends `Ownership-Generation: 2`"
    it "admission_generation 2 reaches the admit runner script and the Ownership-Generation header of write_entry" do
      commands = []
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture2e) do |*args, **_options|
        commands << args
        ["", status]
      end
      allow(Process).to receive(:spawn).and_return(4242)
      allow(Process).to receive(:wait).and_return(nil)
      allow(Process).to receive(:kill)
      WebMock.disable_net_connect!(allow_localhost: true)
      stub_request(:get, %r{/internal/v1/metrics\z}).to_return(status: 200)
      entries = stub_request(:post, %r{/v1/companies/7/entries\z}).to_return(status: 201, body: "{}")
      instance = described_class.start(
        reference_stub: TimekeepingLiveInstance::ReferenceStub.new,
        admission_generation: 2,
        database_url: "postgresql://generation_user@127.0.0.1/timekeeping_generation_live_test"
      )
      begin
        instance.write_entry(company_id: 7, token: "user-token", body: { "note" => "x" })
      ensure
        instance.stop
      end

      runner_scripts = commands.filter_map { |args| args.last if args.include?("runner") }
      expect(runner_scripts.join("\n")).to include("admit!(generation: 2)")
      expect(runner_scripts.join("\n")).not_to include("admit!(generation: 1)")
      expect(entries.with(headers: { "Ownership-Generation" => "2" })).to have_been_requested.once
    end
  end

  context "more tests 4", "port keyword" do
    # "with `port: 45123` given (and the boot commands stubbed), `base_url` is `http://127.0.0.1:45123` and the spawned server command carries `-p 45123`"
    it "an explicit port 45123 drives base_url and the -p argument of the spawned rails server" do
      spawned = []
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture2e).and_return(["", status])
      allow(Process).to receive(:spawn) do |*args, **_options|
        spawned << args
        4242
      end
      allow(Process).to receive(:wait).and_return(nil)
      allow(Process).to receive(:kill)
      WebMock.disable_net_connect!(allow_localhost: true)
      stub_request(:get, "http://127.0.0.1:45123/internal/v1/metrics").to_return(status: 200)
      instance = described_class.start(
        reference_stub: TimekeepingLiveInstance::ReferenceStub.new,
        port: 45123,
        database_url: "postgresql://port_user@127.0.0.1/timekeeping_port_live_test"
      )
      base_url = instance.base_url
      instance.stop

      expect(base_url).to eq("http://127.0.0.1:45123")
      server = spawned.find { |args| args.include?("server") }
      expect(server).not_to be_nil
      expect(server[server.index("-p") + 1]).to eq("45123")
    end
  end

  context "more tests 5", "default port" do
    # "with no `port:`, `base_url` uses a port picked by `free_port`"
    it "without port the instance uses the port free_port picks for base_url and -p" do
      spawned = []
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture2e).and_return(["", status])
      allow(Process).to receive(:spawn) do |*args, **_options|
        spawned << args
        4242
      end
      allow(Process).to receive(:wait).and_return(nil)
      allow(Process).to receive(:kill)
      WebMock.disable_net_connect!(allow_localhost: true)
      stub_request(:get, "http://127.0.0.1:45999/internal/v1/metrics").to_return(status: 200)
      instance = described_class.new(
        reference_stub: TimekeepingLiveInstance::ReferenceStub.new,
        database_url: "postgresql://free_port_user@127.0.0.1/timekeeping_free_port_live_test"
      )
      allow(instance).to receive(:free_port).and_return(45999)
      begin
        instance.start
      ensure
        instance.stop
      end

      expect(instance.base_url).to eq("http://127.0.0.1:45999")
      server = spawned.find { |args| args.include?("server") }
      expect(server[server.index("-p") + 1]).to eq("45999")
      expect(instance).to have_received(:free_port).once
    end
  end

  context "more tests 6", "admission_generation validation" do
    # The generation is written into Ruby source that `rails runner` executes, so only a positive
    # Integer may reach it; anything else must fail before a child process starts.
    it "a non-integer admission_generation is refused before any service command runs" do
      allow(Open3).to receive(:capture2e)
      allow(Process).to receive(:spawn)

      ["2); exit(", 1.5, 0].each do |generation|
        expect {
          described_class.start(
            reference_stub: TimekeepingLiveInstance::ReferenceStub.new,
            admission_generation: generation,
            database_url: "postgresql://bad_generation_user@127.0.0.1/timekeeping_bad_generation_test"
          )
        }.to raise_error(ArgumentError)
      end
      expect(Open3).not_to have_received(:capture2e)
      expect(Process).not_to have_received(:spawn)
    end
  end
end
