# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimekeepingLiveInstance do
  context "more tests 2" do
  it "db:prepare child env carries only the given database_url when global ENV names another" do
    global_url = "postgresql://global_env_user@127.0.0.1/timekeeping_global_env_test"
    checked_url = "postgresql://checked_url_user@127.0.0.1/timekeeping_checked_url_test"
    saved_url = ENV.fetch("TIMEKEEPING_DATABASE_URL", nil)
    ENV["TIMEKEEPING_DATABASE_URL"] = global_url
    allow(Open3).to receive(:capture2e).and_return(["", instance_double(Process::Status, success?: true)])
    allow(Process).to receive(:spawn).and_return(4242)
    allow(Process).to receive(:wait).and_return(nil)
    allow(Process).to receive(:kill)
    stub_request(:get, %r{/internal/v1/metrics\z}).to_return(status: 200)

    instance = described_class.start(reference_stub: TimekeepingLiveInstance::ReferenceStub.new, database_url: checked_url)

    prepare_call = nil
    expect(Open3).to have_received(:capture2e).at_least(:once) do |env, *command, **|
      prepare_call ||= env if command.include?("db:prepare")
    end
    # "When `database_url:` is given, `service_env` uses exactly that value; when nil, it keeps today's `ENV.fetch` and its `BootError`."
    expect(prepare_call.fetch("TIMEKEEPING_DATABASE_URL")).to eq(checked_url)
    expect(prepare_call.values).not_to include(global_url)
    expect(prepare_call).to include("DATABASE_URL" => nil)
  ensure
    instance&.stop
    ENV["TIMEKEEPING_DATABASE_URL"] = saved_url
  end
  end

  context "more tests 3" do
# frozen_string_literal: true
  it "refuses a non-integer admission_generation before any child process runs" do
    allow(Open3).to receive(:capture2e).and_return(["", instance_double(Process::Status, success?: true)])
    allow(Process).to receive(:spawn).and_return(4242)

    # The generation is written into Ruby source that `rails runner` executes, so text must never reach it.
    expect do
      described_class.start(reference_stub: TimekeepingLiveInstance::ReferenceStub.new,
                            admission_generation: "2); exit(")
    end.to raise_error(ArgumentError)
    expect(Open3).not_to have_received(:capture2e)
    expect(Process).not_to have_received(:spawn)
  end
  end
end
