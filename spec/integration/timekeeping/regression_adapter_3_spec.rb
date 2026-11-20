# frozen_string_literal: true

require "rails_helper"

RSpec.describe "TimekeepingRegressionAdapter refusing an unset database URL", committed_data: true do
  # "Ordinary suite: adapter start with TIMEKEEPING_DATABASE_URL unset raises and boots nothing. Spies show
  # `TimekeepingLiveInstance.start` and `Puma::Server.new` never called, the WebMock allow list and both env
  # keys unchanged, and `current` nil."
  it "start! with TIMEKEEPING_DATABASE_URL unset raises BootError naming only the key and boots nothing" do
    skip "The suite's own live adapter is running; this example drives start! from a clean state" if TimekeepingRegressionAdapter.current

    allow(TimekeepingLiveInstance).to receive(:start)
    allow(Puma::Server).to receive(:new).and_call_original
    base_url_env = Timekeeping::EntryApiClient::BASE_URL_ENV
    key_env = Timekeeping::UserToken::PRIVATE_KEY_ENV
    env_before = { base_url_env => ENV.fetch(base_url_env, nil), key_env => ENV.fetch(key_env, nil) }
    allow_list_before = Array(WebMock::Config.instance.allow).dup
    flags = { "TIMEKEEPING_REGRESSION" => "1", "TIMEKEEPING_LIVE" => "1" }

    expect { TimekeepingRegressionAdapter.start!(env: flags, owner_state: "timekeeping") }
      .to raise_error(TimekeepingRegressionAdapter::BootError, /TIMEKEEPING_DATABASE_URL/)

    expect(TimekeepingLiveInstance).not_to have_received(:start)
    expect(Puma::Server).not_to have_received(:new)
    expect(Array(WebMock::Config.instance.allow)).to eq(allow_list_before)
    expect(ENV.fetch(base_url_env, nil)).to eq(env_before[base_url_env])
    expect(ENV.fetch(key_env, nil)).to eq(env_before[key_env])
    expect(TimekeepingRegressionAdapter.current).to be_nil
  end
end

RSpec.describe "TimekeepingRegressionAdapter successful start", committed_data: true do
  # "A \_test URL given in `env:` reaches `TimekeepingLiveInstance.start` as `database_url:` even when global ENV
  # names another URL."
  it "start! passes the env: test URL to the live instance, allows only its port and points the client at it" do
    skip "The suite's own live adapter is running; this example drives start! from a clean state" if TimekeepingRegressionAdapter.current

    base_url_env = Timekeeping::EntryApiClient::BASE_URL_ENV
    key_env = Timekeeping::UserToken::PRIVATE_KEY_ENV
    saved = [base_url_env, key_env, "TIMEKEEPING_DATABASE_URL"].index_with { |key| ENV.fetch(key, nil) }
    key = OpenSSL::PKey::RSA.generate(2048)
    received = nil
    instance = nil
    allow(TimekeepingLiveInstance).to receive(:start) do |**keywords|
      received = keywords
      instance = double("live instance", base_url: "http://127.0.0.1:#{keywords[:port]}", private_key: key,
                                         service_token: "adapter-success-token", admission_generation: 2, stop: nil)
    end
    checked_url = "postgresql://adapter_user@127.0.0.1/timekeeping_adapter_test"
    env = { "TIMEKEEPING_REGRESSION" => "1", "TIMEKEEPING_LIVE" => "1", "TIMEKEEPING_DATABASE_URL" => checked_url }

    begin
      ENV["TIMEKEEPING_DATABASE_URL"] = "postgresql://other_user@127.0.0.1/timekeeping_other_test"
      started = TimekeepingRegressionAdapter.start!(env:, owner_state: "timekeeping")

      expect(received).to include(database_url: checked_url, admission_generation: 2)
      expect(received[:port]).to be_a(Integer)
      expect(received[:reference_stub].service_token).to eq("adapter-success-token")
      expect(started).to be(instance)
      expect(TimekeepingRegressionAdapter.current).to be(instance)
      expect(Array(WebMock::Config.instance.allow)).to eq(["127.0.0.1:#{received[:port]}"])
      expect(ENV.fetch(base_url_env, nil)).to eq("http://127.0.0.1:#{received[:port]}")
      expect(ENV.fetch(key_env, nil)).to eq(key.to_pem)
    ensure
      TimekeepingRegressionAdapter.stop!
      saved.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    end
    expect(instance).to have_received(:stop)
    expect(TimekeepingRegressionAdapter.current).to be_nil
  end
end
