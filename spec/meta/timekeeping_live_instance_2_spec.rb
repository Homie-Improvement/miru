# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimekeepingLiveInstance do
  context "more tests 2" do
    # "with `database_url:` given, the db:prepare child env carries only that URL even when global ENV names another"
    it "db:prepare and the server receive only the database_url value while global ENV names another" do
      global_url = "postgresql://harness_user@127.0.0.1/global_only_test"
      injected_url = "postgresql://harness_user@127.0.0.1/injected_only_test"
      captured = []
      spawned = []
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture2e) { |*args, **_options| captured << args; ["", status] }
      allow(Process).to receive(:spawn) { |*args, **_options| spawned << args; nil }
      instance = described_class.new(reference_stub: TimekeepingLiveInstance::ReferenceStub.new, database_url: injected_url)
      allow(instance).to receive(:start_reference_server)
      allow(instance).to receive(:wait_until_ready)
      original = ENV.fetch("TIMEKEEPING_DATABASE_URL", nil)

      begin
        ENV["TIMEKEEPING_DATABASE_URL"] = global_url
        instance.start
      ensure
        original.nil? ? ENV.delete("TIMEKEEPING_DATABASE_URL") : ENV["TIMEKEEPING_DATABASE_URL"] = original
      end

      prepare_calls = captured.select { |args| args.include?("db:prepare") }
      expect(prepare_calls.size).to eq(1)
      prepare_env = prepare_calls.first.first
      expect(prepare_env.fetch("TIMEKEEPING_DATABASE_URL")).to eq(injected_url)
      expect(prepare_env.values.compact.map(&:to_s)).not_to include(global_url)
      expect(prepare_env).to include("DATABASE_URL" => nil)

      expect(spawned.size).to eq(1)
      expect(spawned.first.first.fetch("TIMEKEEPING_DATABASE_URL")).to eq(injected_url)
    end
  end

  context "more tests 3" do
    # "When `database_url:` is given, `service_env` uses exactly that value; when nil, it keeps today's
    # `ENV.fetch` and its `BootError`."
    it "a blank database_url is passed to db:prepare as given and never falls back to global ENV" do
      global_url = "postgresql://harness_user@127.0.0.1/global_blank_case_test"
      captured = []
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture2e) { |*args, **_options| captured << args; ["", status] }
      allow(Process).to receive(:spawn).and_return(nil)
      instance = described_class.new(reference_stub: TimekeepingLiveInstance::ReferenceStub.new, database_url: "")
      allow(instance).to receive(:start_reference_server)
      allow(instance).to receive(:wait_until_ready)
      original = ENV.fetch("TIMEKEEPING_DATABASE_URL", nil)

      begin
        ENV["TIMEKEEPING_DATABASE_URL"] = global_url
        instance.start
      ensure
        original.nil? ? ENV.delete("TIMEKEEPING_DATABASE_URL") : ENV["TIMEKEEPING_DATABASE_URL"] = original
      end

      prepare_env = captured.find { |args| args.include?("db:prepare") }.first
      expect(prepare_env.fetch("TIMEKEEPING_DATABASE_URL")).to eq("")
      expect(prepare_env.values.compact.map(&:to_s)).not_to include(global_url)
    end
  end

  context "more tests 4" do
    # "when nil, it keeps today's `ENV.fetch` and its `BootError`."
    it "without database_url and with TIMEKEEPING_DATABASE_URL unset start raises BootError before db:prepare" do
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture2e).and_return(["", status])
      allow(Process).to receive(:spawn).and_return(nil)
      instance = described_class.new(reference_stub: TimekeepingLiveInstance::ReferenceStub.new)
      allow(instance).to receive(:start_reference_server)
      allow(instance).to receive(:wait_until_ready)
      original = ENV.fetch("TIMEKEEPING_DATABASE_URL", nil)

      begin
        ENV.delete("TIMEKEEPING_DATABASE_URL")
        expect { instance.start }.to raise_error(TimekeepingLiveInstance::BootError)
      ensure
        ENV["TIMEKEEPING_DATABASE_URL"] = original unless original.nil?
      end

      expect(Open3).not_to have_received(:capture2e)
    end
  end
end
