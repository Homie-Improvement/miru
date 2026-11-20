# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimekeepingLiveInstance do
  context "more tests 2" do
    # "with `database_url:` given, the db:prepare child env carries only that URL even when global ENV names another"
    it "start with database_url gives db:prepare only that URL even when global ENV names another" do
      global_url = "postgresql://global_user@127.0.0.1/timekeeping_global_lens_test"
      given_url = "postgresql://given_user@127.0.0.1/timekeeping_given_lens_test"
      original = ENV.fetch("TIMEKEEPING_DATABASE_URL", nil)
      ENV["TIMEKEEPING_DATABASE_URL"] = global_url
      commands = []
      allow(Bundler).to receive(:with_unbundled_env) { |&block| block.call }
      allow(Open3).to receive(:capture2e) do |*args, **|
        commands << args
        ["", instance_double(Process::Status, success?: true)]
      end
      allow(Process).to receive(:spawn).and_return(4242)
      allow(Process).to receive(:wait).and_return(nil)
      allow(Process).to receive(:kill)
      stub_request(:get, %r{/internal/v1/metrics\z}).to_return(status: 200)

      instance = described_class.start(reference_stub: described_class::ReferenceStub.new, database_url: given_url)

      prepare = commands.find { |args| args.include?("db:prepare") }
      expect(prepare).not_to be_nil
      env = prepare.first
      expect(env.fetch("TIMEKEEPING_DATABASE_URL")).to eq(given_url)
      expect(env.fetch("DATABASE_URL")).to be_nil
      expect(env.values.compact.map(&:to_s).grep(/timekeeping_global_lens_test/)).to be_empty
    ensure
      instance&.stop
      original.nil? ? ENV.delete("TIMEKEEPING_DATABASE_URL") : ENV["TIMEKEEPING_DATABASE_URL"] = original
    end
  end

  context "more tests 3" do
    # "with `port: 45123` given (and the boot commands stubbed), `base_url` is `http://127.0.0.1:45123` and the spawned server command carries `-p 45123`"
    it "start with port 45123 serves base_url on 45123 and passes -p 45123 to the server without picking a free port" do
      spawned = []
      allow(Bundler).to receive(:with_unbundled_env) { |&block| block.call }
      allow(Open3).to receive(:capture2e).and_return(["", instance_double(Process::Status, success?: true)])
      allow(Process).to receive(:spawn) do |*args, **|
        spawned << args
        4242
      end
      allow(Process).to receive(:wait).and_return(nil)
      allow(Process).to receive(:kill)
      stub_request(:get, "http://127.0.0.1:45123/internal/v1/metrics").to_return(status: 200)

      instance = described_class.new(reference_stub: described_class::ReferenceStub.new, port: 45123,
                                     database_url: "postgresql://port_user@127.0.0.1/timekeeping_port_lens_test")
      allow(instance).to receive(:free_port).and_return(45999)
      instance.start

      expect(instance.base_url).to eq("http://127.0.0.1:45123")
      server = spawned.find { |args| args.include?("server") }
      expect(server[server.index("-p") + 1]).to eq("45123")
      expect(instance).not_to have_received(:free_port)
    ensure
      instance&.stop
    end
  end

  context "more tests 4" do
    # "with no `port:`, `base_url` uses a port picked by `free_port`"
    it "start without port uses the one port free_port picks for base_url and -p" do
      spawned = []
      allow(Bundler).to receive(:with_unbundled_env) { |&block| block.call }
      allow(Open3).to receive(:capture2e).and_return(["", instance_double(Process::Status, success?: true)])
      allow(Process).to receive(:spawn) do |*args, **|
        spawned << args
        4242
      end
      allow(Process).to receive(:wait).and_return(nil)
      allow(Process).to receive(:kill)
      stub_request(:get, "http://127.0.0.1:45999/internal/v1/metrics").to_return(status: 200)

      instance = described_class.new(reference_stub: described_class::ReferenceStub.new,
                                     database_url: "postgresql://free_user@127.0.0.1/timekeeping_free_lens_test")
      allow(instance).to receive(:free_port).and_return(45999)
      instance.start

      expect(instance.base_url).to eq("http://127.0.0.1:45999")
      server = spawned.find { |args| args.include?("server") }
      expect(server[server.index("-p") + 1]).to eq("45999")
      expect(instance).to have_received(:free_port).once
    ensure
      instance&.stop
    end
  end

  context "more tests 5" do
    # "`TimekeepingLiveInstance.start(reference_stub:, admission_generation: 2)` admits generation 2 and `write_entry` sends `Ownership-Generation: 2`"
    it "start with admission_generation 2 admits generation 2 and write_entry sends Ownership-Generation 2" do
      commands = []
      allow(Bundler).to receive(:with_unbundled_env) { |&block| block.call }
      allow(Open3).to receive(:capture2e) do |*args, **|
        commands << args
        ["", instance_double(Process::Status, success?: true)]
      end
      allow(Process).to receive(:spawn).and_return(4242)
      allow(Process).to receive(:wait).and_return(nil)
      allow(Process).to receive(:kill)
      stub_request(:get, "http://127.0.0.1:45123/internal/v1/metrics").to_return(status: 200)
      entry = stub_request(:post, "http://127.0.0.1:45123/v1/companies/7/entries")
        .with(headers: { "Ownership-Generation" => "2" })
        .to_return(status: 201, body: "{}")

      instance = described_class.start(reference_stub: described_class::ReferenceStub.new, admission_generation: 2,
                                       port: 45123, database_url: "postgresql://gen_user@127.0.0.1/timekeeping_gen_lens_test")
      instance.write_entry(company_id: 7, token: "user-token", body: { "hours" => 1 })

      admit = commands.find { |args| args.include?("runner") && args.last.include?("admit!") }
      expect(admit.last).to include("admit!(generation: 2)")
      expect(admit.last).not_to include("admit!(generation: 1)")
      expect(entry).to have_been_requested.once
    ensure
      instance&.stop
    end
  end

  context "more tests 6" do
    # "its `ADMIT_SCRIPT` and `write_entry`'s `Ownership-Generation` header use the generation, so existing callers keep generation 1."
    it "start without admission_generation keeps generation 1 in the admit script and the Ownership-Generation header" do
      commands = []
      allow(Bundler).to receive(:with_unbundled_env) { |&block| block.call }
      allow(Open3).to receive(:capture2e) do |*args, **|
        commands << args
        ["", instance_double(Process::Status, success?: true)]
      end
      allow(Process).to receive(:spawn).and_return(4242)
      allow(Process).to receive(:wait).and_return(nil)
      allow(Process).to receive(:kill)
      stub_request(:get, "http://127.0.0.1:45124/internal/v1/metrics").to_return(status: 200)
      entry = stub_request(:post, "http://127.0.0.1:45124/v1/companies/7/entries")
        .with(headers: { "Ownership-Generation" => "1" })
        .to_return(status: 201, body: "{}")

      instance = described_class.start(reference_stub: described_class::ReferenceStub.new, port: 45124,
                                       database_url: "postgresql://gen_user@127.0.0.1/timekeeping_gen_lens_test")
      instance.write_entry(company_id: 7, token: "user-token", body: { "hours" => 1 })

      admit = commands.find { |args| args.include?("runner") && args.last.include?("admit!") }
      expect(admit.last).to include("admit!(generation: 1)")
      expect(entry).to have_been_requested.once
    ensure
      instance&.stop
    end
  end

  context "more tests 7" do
    # The generation is written into Ruby source that `rails runner` executes, so only a positive
    # Integer may reach it; the plan refuses anything else with ArgumentError before any spawn.
    it "accepts admission_generation 2 but refuses a non-integer generation before any child process runs" do
      reference = described_class::ReferenceStub.new
      allow(Open3).to receive(:capture2e)
      allow(Process).to receive(:spawn)

      expect { described_class.new(reference_stub: reference, admission_generation: 2) }.not_to raise_error

      ["2); exit(", 1.5, 0].each do |generation|
        expect { described_class.start(reference_stub: reference, admission_generation: generation) }
          .to raise_error(ArgumentError)
      end
      expect(Open3).not_to have_received(:capture2e)
      expect(Process).not_to have_received(:spawn)
    end
  end

  context "more tests 8" do
    # A blank URL in the child env would let Rails fall back to a default database; the plan's
    # chosen handling (disclosed in the pull request) is to refuse it with ArgumentError.
    it "accepts a non-blank database_url but refuses a blank one before any child process runs" do
      reference = described_class::ReferenceStub.new
      allow(Open3).to receive(:capture2e)
      allow(Process).to receive(:spawn)

      expect do
        described_class.new(reference_stub: reference, database_url: "postgresql://blank_user@127.0.0.1/timekeeping_blank_lens_test")
      end.not_to raise_error

      ["", "   "].each do |blank|
        expect { described_class.start(reference_stub: reference, database_url: blank) }.to raise_error(ArgumentError)
      end
      expect(Open3).not_to have_received(:capture2e)
      expect(Process).not_to have_received(:spawn)
    end
  end

  context "more tests 9" do
    it "start with database_url nil and no global TIMEKEEPING_DATABASE_URL raises BootError before db:prepare" do
      allow(Open3).to receive(:capture2e).and_return(["", instance_double(Process::Status, success?: true)])
      allow(Process).to receive(:spawn).and_return(4242)
      allow(Process).to receive(:wait).and_return(nil)
      allow(Process).to receive(:kill)
      saved_url = ENV.delete("TIMEKEEPING_DATABASE_URL")

      begin
        # "When `database_url:` is given, `service_env` uses exactly that value; when nil, it keeps today's `ENV.fetch` and its `BootError`."
        expect do
          described_class.start(reference_stub: TimekeepingLiveInstance::ReferenceStub.new, database_url: nil)
        end.to raise_error(TimekeepingLiveInstance::BootError, /TIMEKEEPING_DATABASE_URL/)
      ensure
        ENV["TIMEKEEPING_DATABASE_URL"] = saved_url if saved_url
      end
      expect(Open3).not_to have_received(:capture2e)
      expect(Process).not_to have_received(:spawn)
    end
  end
end
