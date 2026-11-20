# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimekeepingLiveInstance do
  context "more tests 2", "database_url keyword against a global URL" do
    # "with `database_url:` given, the db:prepare child env carries only that URL even when global ENV names another"
    it "db:prepare child env carries only the database_url value even when global ENV names another URL" do
      global_url = "postgresql://global_adversary@127.0.0.1/timekeeping_global_adversary_test"
      given_url = "postgresql://given_adversary@127.0.0.1/timekeeping_given_adversary_test"
      previous = ENV.fetch("TIMEKEEPING_DATABASE_URL", nil)
      ENV["TIMEKEEPING_DATABASE_URL"] = global_url
      calls = []
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture2e) do |env, *command, **|
        calls << [env, command]
        ["", status]
      end
      allow(Process).to receive(:spawn).and_return(4242)
      allow(Process).to receive(:wait).and_return(nil)
      allow(Process).to receive(:kill)
      stub_request(:get, %r{/internal/v1/metrics\z}).to_return(status: 200)
      instance = nil
      begin
        instance = described_class.start(reference_stub: TimekeepingLiveInstance::ReferenceStub.new, database_url: given_url)
        prepare_env, = calls.find { |_env, command| command.include?("db:prepare") }

        expect(prepare_env.fetch("TIMEKEEPING_DATABASE_URL")).to eq(given_url)
        expect(prepare_env.values).not_to include(global_url)
        expect(prepare_env.values.compact.join("\n")).not_to include(global_url)
        expect(prepare_env).to include("DATABASE_URL" => nil)
      ensure
        instance&.stop
        previous.nil? ? ENV.delete("TIMEKEEPING_DATABASE_URL") : ENV["TIMEKEEPING_DATABASE_URL"] = previous
      end
    end
  end

  context "more tests 3", "admission_generation that is not a positive Integer" do
    # The generation is written into Ruby source that `rails runner` executes, so text such as
    # "2); exit(" must never reach it; the plan raises ArgumentError before any child starts.
    it "refuses a non-integer admission_generation before any child process runs" do
      allow(Open3).to receive(:capture2e)
      allow(Process).to receive(:spawn)

      ["2); exit(", 1.5, 0].each do |generation|
        expect do
          described_class.start(reference_stub: TimekeepingLiveInstance::ReferenceStub.new, admission_generation: generation)
        end.to raise_error(ArgumentError)
      end
      expect(Open3).not_to have_received(:capture2e)
      expect(Process).not_to have_received(:spawn)
    end
  end

  context "more tests 4", "blank database_url" do
    # The issue's rule separates a given URL from nil and is silent on a blank one; the plan chose to
    # raise ArgumentError so a blank URL never reaches db:prepare. This choice must be disclosed.
    it "refuses a blank database_url before db:prepare can fall back to another database" do
      allow(Open3).to receive(:capture2e)
      allow(Process).to receive(:spawn)

      ["", "   "].each do |blank|
        expect do
          described_class.start(reference_stub: TimekeepingLiveInstance::ReferenceStub.new, database_url: blank)
        end.to raise_error(ArgumentError)
      end
      expect(Open3).not_to have_received(:capture2e)
      expect(Process).not_to have_received(:spawn)
    end
  end

  context "more tests 5", "explicit port keyword" do
    # "use the given port when one is passed (both for `base_url` and for the `rails server -p` argument)"
    it "a given port drives base_url, the -p argument and the pid file together" do
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture2e).and_return(["", status])
      spawned = []
      allow(Process).to receive(:spawn) do |_env, *command, **|
        spawned << command
        4242
      end
      allow(Process).to receive(:wait).and_return(nil)
      allow(Process).to receive(:kill)
      stub_request(:get, %r{/internal/v1/metrics\z}).to_return(status: 200)
      instance = nil
      begin
        # A database_url keeps this example independent of the caller's TIMEKEEPING_DATABASE_URL.
        instance = described_class.start(reference_stub: TimekeepingLiveInstance::ReferenceStub.new, port: 45123,
                                          database_url: "postgresql://port_example@127.0.0.1/timekeeping_port_example_test")
        server = spawned.find { |command| command.include?("server") }

        expect(instance.base_url).to eq("http://127.0.0.1:45123")
        expect(server[server.index("-p") + 1]).to eq("45123")
        expect(server[server.index("-P") + 1]).to end_with("timekeeping-live-45123.pid")
      ensure
        instance&.stop
      end
    end
  end
end
