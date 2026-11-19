# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimekeepingLiveInstance do
  context "more tests 11" do
    # "When `database_url:` is given, `service_env` uses exactly that value; when nil, it keeps today's `ENV.fetch` and its `BootError`."
    # A blank value is passed through as given; the caller's guard check is what refuses it.
    it "start never falls back to the global URL when database_url is given as a blank string" do
      global_url = "postgresql://global_user@127.0.0.1/global_unchecked_test"
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("TIMEKEEPING_DATABASE_URL").and_return(global_url)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TIMEKEEPING_DATABASE_URL").and_return(global_url)

      prepare_envs = []
      success = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture2e) do |env, *command, **_options|
        prepare_envs << env if command.include?("db:prepare")
        ["", success]
      end
      allow(Process).to receive(:spawn).and_return(nil)

      instance = described_class.new(reference_stub: TimekeepingLiveInstance::ReferenceStub.new, database_url: "")
      allow(instance).to receive(:start_reference_server)
      allow(instance).to receive(:wait_until_ready)

      instance.start

      expect(prepare_envs.size).to eq(1)
      expect(prepare_envs.first.fetch("TIMEKEEPING_DATABASE_URL")).to eq("")
      expect(prepare_envs.first.values.compact.map(&:to_s)).not_to include(a_string_including("global_unchecked_test"))
    ensure
      instance&.stop
    end
  end

  context "more tests 12" do
    it "every child of an instance given database_url opens only that URL even when global ENV names another" do
      global_url = "postgresql://u@127.0.0.1/global_live_test"
      injected_url = "postgresql://u@127.0.0.1/injected_live_test"
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("TIMEKEEPING_DATABASE_URL").and_return(global_url)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TIMEKEEPING_DATABASE_URL").and_return(global_url)

      child_envs = []
      allow(Open3).to receive(:capture2e) do |env, *command, **_options|
        child_envs << [command, env]
        ["", instance_double(Process::Status, success?: true)]
      end
      allow(Process).to receive(:spawn) do |env, *command, **_options|
        child_envs << [command, env]
        nil
      end

      instance = described_class.new(reference_stub: TimekeepingLiveInstance::ReferenceStub.new,
                                     database_url: injected_url, port: 45123)
      allow(instance).to receive(:start_reference_server)
      allow(instance).to receive(:wait_until_ready)

      instance.start

      # "with `database_url:` given, the db:prepare child env carries only that URL even when global ENV names another"
      prepare_envs = child_envs.filter_map { |command, env| env if command.include?("db:prepare") }
      expect(prepare_envs.size).to eq(1)
      expect(prepare_envs.first.fetch("TIMEKEEPING_DATABASE_URL")).to eq(injected_url)
      expect(prepare_envs.first.values).not_to include(global_url)
      expect(prepare_envs.first).to include("DATABASE_URL" => nil)

      # The admit runner and the spawned server must open the same database db:prepare prepared.
      expect(child_envs.size).to be >= 3
      expect(child_envs.count { |command, _env| command.include?("server") }).to eq(1)
      child_envs.each do |command, env|
        expect(env.fetch("TIMEKEEPING_DATABASE_URL")).to eq(injected_url), "#{command.join(" ")} opened another database"
        expect(env.values.compact.map(&:to_s)).not_to include(a_string_including(global_url))
        expect(env.fetch("DATABASE_URL")).to be_nil
      end
    ensure
      instance&.stop
    end
  end

  context "more tests 14" do
    it "with database_url nil and TIMEKEEPING_DATABASE_URL unset, start raises BootError before db:prepare runs" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("TIMEKEEPING_DATABASE_URL") do |key, &missing|
        missing ? missing.call(key) : raise(KeyError, "key not found: #{key.inspect}")
      end
      allow(Open3).to receive(:capture2e).and_return(["", instance_double(Process::Status, success?: true)])
      allow(Process).to receive(:spawn).and_return(nil)

      instance = described_class.new(reference_stub: TimekeepingLiveInstance::ReferenceStub.new,
                                     database_url: nil, port: 45125)
      allow(instance).to receive(:start_reference_server)
      allow(instance).to receive(:wait_until_ready)

      # "When `database_url:` is given, `service_env` uses exactly that value; when nil, it keeps today's `ENV.fetch` and its `BootError`."
      expect { instance.start }.to raise_error(TimekeepingLiveInstance::BootError)
      expect(Open3).not_to have_received(:capture2e)
      expect(Process).not_to have_received(:spawn)
    ensure
      instance&.stop
    end
  end

  context "more tests 15" do
    # "with `port: 45123` given (and the boot commands stubbed), `base_url` is `http://127.0.0.1:45123` and the
    # spawned server command carries `-p 45123`"
    it "an explicit port 45123 sets base_url and the server -p argument without picking a free port" do
      spawned = []
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture2e).and_return(["", status])
      allow(Process).to receive(:spawn) { |*args, **_options| spawned << args; nil }
      instance = described_class.new(reference_stub: TimekeepingLiveInstance::ReferenceStub.new, port: 45_123,
                                     database_url: "postgresql://harness_user@127.0.0.1/port_case_test")
      allow(instance).to receive(:start_reference_server)
      allow(instance).to receive(:wait_until_ready)
      allow(instance).to receive(:free_port).and_return(45_999)

      instance.start

      expect(instance.base_url).to eq("http://127.0.0.1:45123")
      expect(spawned.size).to eq(1)
      argv = spawned.first.drop(1)
      expect(argv.each_cons(2).to_a).to include(["-p", "45123"])
      expect(instance).not_to have_received(:free_port)
    end
  end

  context "more tests 16" do
    # "with no `port:`, `base_url` uses a port picked by `free_port`."
    it "without port base_url and the server -p argument use the port free_port picked" do
      spawned = []
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture2e).and_return(["", status])
      allow(Process).to receive(:spawn) { |*args, **_options| spawned << args; nil }
      instance = described_class.new(reference_stub: TimekeepingLiveInstance::ReferenceStub.new,
                                     database_url: "postgresql://harness_user@127.0.0.1/free_port_case_test")
      allow(instance).to receive(:start_reference_server)
      allow(instance).to receive(:wait_until_ready)
      allow(instance).to receive(:free_port).and_return(45_999)

      instance.start

      expect(instance.base_url).to eq("http://127.0.0.1:45999")
      expect(spawned.first.drop(1).each_cons(2).to_a).to include(["-p", "45999"])
    end
  end

  context "more tests 17" do
    # "Add `admission_generation:` (default 1) and `port:` (default a free port) to `TimekeepingLiveInstance.start`/`new`;
    # its `ADMIT_SCRIPT` and `write_entry`'s `Ownership-Generation` header use the generation, so existing callers keep
    # generation 1."
    it "the admit runner script admits generation 2 when asked and generation 1 by default" do
      status = instance_double(Process::Status, success?: true)
      allow(Process).to receive(:spawn).and_return(nil)
      admit_scripts = lambda do |**keywords|
        captured = []
        allow(Open3).to receive(:capture2e) { |*args, **_options| captured << args; ["", status] }
        instance = described_class.new(reference_stub: TimekeepingLiveInstance::ReferenceStub.new,
                                       database_url: "postgresql://harness_user@127.0.0.1/admit_case_test", **keywords)
        allow(instance).to receive(:start_reference_server)
        allow(instance).to receive(:wait_until_ready)
        instance.start
        captured.filter_map { |args| args.last if args.include?("runner") }.grep(/admit!/)
      end

      second = admit_scripts.call(admission_generation: 2)
      expect(second.size).to eq(1)
      expect(second.first).to include("admit!(generation: 2)")
      expect(second.first).not_to include("admit!(generation: 1)")

      default = admit_scripts.call
      expect(default.size).to eq(1)
      expect(default.first).to include("admit!(generation: 1)")
    end
  end

  context "more tests 18" do
    # "`TimekeepingLiveInstance.start(reference_stub:, admission_generation: 2)` admits generation 2 and
    # `write_entry` sends `Ownership-Generation: 2`"
    it "write_entry sends Ownership-Generation 2 for a generation 2 instance and 1 by default" do
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture2e).and_return(["", status])
      allow(Process).to receive(:spawn).and_return(nil)
      started = lambda do |port, **keywords|
        instance = described_class.new(reference_stub: TimekeepingLiveInstance::ReferenceStub.new, port:,
                                       database_url: "postgresql://harness_user@127.0.0.1/header_case_test", **keywords)
        allow(instance).to receive(:start_reference_server)
        allow(instance).to receive(:wait_until_ready)
        instance.start
        instance
      end
      stub_request(:post, "http://127.0.0.1:45123/v1/companies/7/entries").to_return(status: 201, body: "{}")
      stub_request(:post, "http://127.0.0.1:45124/v1/companies/7/entries").to_return(status: 201, body: "{}")

      started.call(45_123, admission_generation: 2).write_entry(company_id: 7, token: "user-token", body: {})
      started.call(45_124).write_entry(company_id: 7, token: "user-token", body: {})

      expect(a_request(:post, "http://127.0.0.1:45123/v1/companies/7/entries")
        .with(headers: { "Ownership-Generation" => "2" })).to have_been_made.once
      expect(a_request(:post, "http://127.0.0.1:45124/v1/companies/7/entries")
        .with(headers: { "Ownership-Generation" => "1" })).to have_been_made.once
    end
  end

  context "more tests 20" do
    it "start and new both take optional admission_generation, port and database_url keywords" do
      # "The signature is `TimekeepingLiveInstance.start(reference_stub:, admission_generation: 1, port: nil, database_url: nil)`."
      # "Also add `database_url:` (default nil) to `start` and `new`."
      expected = [[:keyreq, :reference_stub], [:key, :admission_generation], [:key, :port], [:key, :database_url]]
      expect(described_class.method(:start).parameters).to eq(expected)
      expect(described_class.instance_method(:initialize).parameters).to eq(expected)

      instance = described_class.new(
        reference_stub: TimekeepingLiveInstance::ReferenceStub.new,
        admission_generation: 2, port: 45123, database_url: "postgresql://u@127.0.0.1/keyword_check_test"
      )
      expect(instance).to be_a(described_class)
    end
  end

  context "more tests 24" do
    # "its `ADMIT_SCRIPT` and `write_entry`'s `Ownership-Generation` header use the generation"
    # The admit script is Ruby source run by rails runner, so a non-Integer generation must never
    # reach it as text, and the script and the header must read one checked value.
    it "refuses a generation that is not a positive Integer before any child runs" do
      allow(Open3).to receive(:capture2e)
      allow(Process).to receive(:spawn)
      reference_stub = TimekeepingLiveInstance::ReferenceStub.new

      ["2", "1); Kernel.exit(0", 0, -1, 2.5, nil].each do |generation|
        expect { described_class.new(reference_stub:, admission_generation: generation) }
          .to raise_error(ArgumentError)
      end
      expect(Open3).not_to have_received(:capture2e)
      expect(Process).not_to have_received(:spawn)
    end
  end
end
