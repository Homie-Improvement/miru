# frozen_string_literal: true

require "rails_helper"

RSpec.describe "TimekeepingRegressionAdapter when the live instance fails to start", committed_data: true do
  it "a failed TimekeepingLiveInstance.start leaves current nil, the env keys and the WebMock allow list as they were, and an error without the URL, token or key" do
    skip "The suite's live adapter is running; this example drives start! from a clean state" if TimekeepingRegressionAdapter.current

    url = "postgresql://adapter_user:adapter-secret@127.0.0.1/timekeeping_adapter_test"
    env = { "TIMEKEEPING_REGRESSION" => "1", "TIMEKEEPING_LIVE" => "1", "TIMEKEEPING_DATABASE_URL" => url }
    keys = [Timekeeping::EntryApiClient::BASE_URL_ENV, Timekeeping::UserToken::PRIVATE_KEY_ENV]
    env_before = keys.index_with { |key| ENV.fetch(key, nil) }
    webmock_config = WebMock::Config.instance
    allow_list_before = webmock_config.allow
    net_connect_before = webmock_config.allow_net_connect
    leaked_token = "live-service-leaked-token"
    leaked_key = "-----BEGIN RSA PRIVATE KEY-----"
    # The live instance's own boot errors carry raw child output, which can hold all three.
    allow(TimekeepingLiveInstance).to receive(:start)
      .and_raise(TimekeepingLiveInstance::BootError, "db:prepare failed:\n#{url}\n#{leaked_token}\n#{leaked_key}")

    error = nil
    begin
      TimekeepingRegressionAdapter.start!(env:, owner_state: "timekeeping")
    rescue StandardError => e
      error = e
    end

    observed_env = keys.index_with { |key| ENV.fetch(key, nil) }
    observed_allow_list = webmock_config.allow
    observed_net_connect = webmock_config.allow_net_connect
    env_before.each { |key, value| ENV[key] = value }
    webmock_config.allow = allow_list_before
    webmock_config.allow_net_connect = net_connect_before

    # "a failed start leaves `TimekeepingRegressionAdapter.current` nil and the error carries no URL, token or key"
    expect(error).to be_a(TimekeepingRegressionAdapter::BootError)
    expect(TimekeepingRegressionAdapter.current).to be_nil
    chain = []
    current_error = error
    while current_error
      chain << current_error.message
      current_error = current_error.cause
    end
    chain.each do |message|
      expect(message).not_to include(url)
      expect(message).not_to include("adapter-secret")
      expect(message).not_to include(leaked_token)
      expect(message).not_to include(leaked_key)
    end
    # "If anything fails after the instance began, stop it and leave `current` nil."
    expect(observed_env).to eq(env_before)
    expect(observed_allow_list).to eq(allow_list_before)
    expect(observed_net_connect).to eq(net_connect_before)
  end
end

RSpec.describe "TimekeepingRegressionAdapter when a step after the instance start fails", committed_data: true do
  it "a failure after the live instance began stops that instance and leaves current nil and both env keys unchanged" do
    skip "The suite's live adapter is running; this example drives start! from a clean state" if TimekeepingRegressionAdapter.current

    url = "postgresql://127.0.0.1/timekeeping_adapter_test"
    env = { "TIMEKEEPING_REGRESSION" => "1", "TIMEKEEPING_LIVE" => "1", "TIMEKEEPING_DATABASE_URL" => url }
    keys = [Timekeeping::EntryApiClient::BASE_URL_ENV, Timekeeping::UserToken::PRIVATE_KEY_ENV]
    env_before = keys.index_with { |key| ENV.fetch(key, nil) }
    webmock_config = WebMock::Config.instance
    allow_list_before = webmock_config.allow
    net_connect_before = webmock_config.allow_net_connect
    instance = instance_double(TimekeepingLiveInstance, service_token: "live-service-started", base_url: "http://127.0.0.1:4999",
                                                        private_key: OpenSSL::PKey::RSA.new(2048), stop: nil)
    allow(TimekeepingLiveInstance).to receive(:start).and_return(instance)
    # Setting the reference stub's token is the first step after the instance has started.
    allow_any_instance_of(TimekeepingLiveInstance::ReferenceStub).to receive(:service_token=)
      .and_raise(RuntimeError, "could not set token for #{url}")

    error = nil
    begin
      TimekeepingRegressionAdapter.start!(env:, owner_state: "timekeeping")
    rescue StandardError => e
      error = e
    end

    observed_env = keys.index_with { |key| ENV.fetch(key, nil) }
    env_before.each { |key, value| ENV[key] = value }
    webmock_config.allow = allow_list_before
    webmock_config.allow_net_connect = net_connect_before

    # "If anything fails after the instance began, stop it and leave `current` nil."
    expect(error).to be_a(TimekeepingRegressionAdapter::BootError)
    expect(error.message).not_to include(url)
    expect(instance).to have_received(:stop)
    expect(TimekeepingRegressionAdapter.current).to be_nil
    expect(observed_env).to eq(env_before)
  end
end

RSpec.describe "TimekeepingRegressionAdapter start and stop state", committed_data: true do
  it "a successful start stores current and sets both env keys from the instance, and stop! stops it and clears current" do
    skip "The suite's live adapter is running; this example drives start! from a clean state" if TimekeepingRegressionAdapter.current

    url = "postgresql://127.0.0.1/timekeeping_adapter_test"
    env = { "TIMEKEEPING_REGRESSION" => "1", "TIMEKEEPING_LIVE" => "1", "TIMEKEEPING_DATABASE_URL" => url }
    keys = [Timekeeping::EntryApiClient::BASE_URL_ENV, Timekeeping::UserToken::PRIVATE_KEY_ENV]
    env_before = keys.index_with { |key| ENV.fetch(key, nil) }
    webmock_config = WebMock::Config.instance
    allow_list_before = webmock_config.allow
    net_connect_before = webmock_config.allow_net_connect
    private_key = OpenSSL::PKey::RSA.new(2048)
    instance = instance_double(TimekeepingLiveInstance, service_token: "live-service-started", base_url: "http://127.0.0.1:4999",
                                                        private_key:, stop: nil)
    allow(TimekeepingLiveInstance).to receive(:start).and_return(instance)

    begin
      returned = TimekeepingRegressionAdapter.start!(env:, owner_state: "timekeeping")
      stored = TimekeepingRegressionAdapter.current
      observed_base_url = ENV.fetch(Timekeeping::EntryApiClient::BASE_URL_ENV, nil)
      observed_key = ENV.fetch(Timekeeping::UserToken::PRIVATE_KEY_ENV, nil)
    ensure
      TimekeepingRegressionAdapter.stop!
      env_before.each { |key, value| ENV[key] = value }
      webmock_config.allow = allow_list_before
      webmock_config.allow_net_connect = net_connect_before
    end

    # "set the two env keys; store the instance as `current`"
    expect(returned).to eq(instance)
    expect(stored).to eq(instance)
    expect(observed_base_url).to eq("http://127.0.0.1:4999")
    expect(observed_key).to eq(private_key.to_pem)
    # "An `after(:suite)` hook stops the instance."
    expect(instance).to have_received(:stop)
    expect(TimekeepingRegressionAdapter.current).to be_nil
  end
end
