# frozen_string_literal: true

require "rails_helper"
require "net/http"
require "socket"

RSpec.describe "TimekeepingRegressionAdapter refuses an unset database URL", committed_data: true do
  before do
    skip "The suite's own live adapter is running; this example drives start! from a clean state" if TimekeepingRegressionAdapter.current
  end

  # "adapter start with TIMEKEEPING_DATABASE_URL unset raises and boots nothing"
  it "start! with TIMEKEEPING_DATABASE_URL unset raises BootError naming only the key and boots nothing" do
    allow(TimekeepingLiveInstance).to receive(:start)
    allow(Puma::Server).to receive(:new).and_call_original
    env = { "TIMEKEEPING_REGRESSION" => "1", "TIMEKEEPING_LIVE" => "1" }

    with_timekeeping_env(
      Timekeeping::EntryApiClient::BASE_URL_ENV => "http://outer-before.test",
      Timekeeping::UserToken::PRIVATE_KEY_ENV => "outer-before-key"
    ) do
      allow_list_before = WebMock::Config.instance.allow.dup
      allow_net_connect_before = WebMock::Config.instance.allow_net_connect

      expect { TimekeepingRegressionAdapter.start!(env:, owner_state: "timekeeping") }
        .to raise_error(TimekeepingRegressionAdapter::BootError, /TIMEKEEPING_DATABASE_URL/)

      expect(TimekeepingLiveInstance).not_to have_received(:start)
      expect(Puma::Server).not_to have_received(:new)
      expect(WebMock::Config.instance.allow).to eq(allow_list_before)
      expect(WebMock::Config.instance.allow_net_connect).to eq(allow_net_connect_before)
      expect(ENV.fetch(Timekeeping::EntryApiClient::BASE_URL_ENV, nil)).to eq("http://outer-before.test")
      expect(ENV.fetch(Timekeeping::UserToken::PRIVATE_KEY_ENV, nil)).to eq("outer-before-key")
      expect(TimekeepingRegressionAdapter.current).to be_nil
    end
  end
end

RSpec.describe "TimekeepingRegressionAdapter refuses a non-test database URL", committed_data: true do
  before do
    skip "The suite's own live adapter is running; this example drives start! from a clean state" if TimekeepingRegressionAdapter.current
  end

  # "A URL whose libpq name ends in \_test but whose Active Record name does not is refused before db:prepare."
  it "start! refuses a URL whose Active Record name does not end in _test before the live instance starts" do
    allow(TimekeepingLiveInstance).to receive(:start)
    allow(Puma::Server).to receive(:new).and_call_original
    url = "postgresql://harness_selector_user@127.0.0.1/timekeeping_development?dbname=timekeeping_selector_test"
    env = { "TIMEKEEPING_REGRESSION" => "1", "TIMEKEEPING_LIVE" => "1", "TIMEKEEPING_DATABASE_URL" => url }
    allow_list_before = WebMock::Config.instance.allow.dup

    error = nil
    begin
      TimekeepingRegressionAdapter.start!(env:, owner_state: "timekeeping")
    rescue StandardError => e
      error = e
    end

    expect(error).to be_a(TestDatabaseGuard::NotATestDatabase)
    # "No error message carries the URL, the service token or the private key."
    expect(error.message).not_to include(url)
    expect(error.message).not_to include("harness_selector_user")
    expect(TimekeepingLiveInstance).not_to have_received(:start)
    expect(Puma::Server).not_to have_received(:new)
    expect(WebMock::Config.instance.allow).to eq(allow_list_before)
    expect(TimekeepingRegressionAdapter.current).to be_nil
  end
end

RSpec.describe "TimekeepingRegressionAdapter error hygiene when the instance fails to start", committed_data: true do
  before do
    skip "The suite's own live adapter is running; this example drives start! from a clean state" if TimekeepingRegressionAdapter.current
  end

  # "If anything fails after the instance began, stop it and leave `current` nil. No error message carries the URL,
  # the service token or the private key."
  it "a failing live instance start leaves current nil and the error and its causes carry no URL, token or key" do
    url = "postgresql://secret_harness_user:hunter2secret@127.0.0.1/timekeeping_regression_test"
    token = "live-service-leakedtoken0123456789"
    pem = OpenSSL::PKey::RSA.generate(2048).to_pem
    allow(TimekeepingLiveInstance).to receive(:start)
      .and_raise(TimekeepingLiveInstance::BootError, "bundle exec rails db:prepare failed:\n#{url}\n#{token}\n#{pem}")
    env = { "TIMEKEEPING_REGRESSION" => "1", "TIMEKEEPING_LIVE" => "1", "TIMEKEEPING_DATABASE_URL" => url }

    with_timekeeping_env(
      Timekeeping::EntryApiClient::BASE_URL_ENV => "http://outer-before.test",
      Timekeeping::UserToken::PRIVATE_KEY_ENV => "outer-before-key"
    ) do
      allow_list_before = WebMock::Config.instance.allow.dup
      error = nil
      begin
        TimekeepingRegressionAdapter.start!(env:, owner_state: "timekeeping")
      rescue StandardError => e
        error = e
      end

      expect(error).to be_a(TimekeepingRegressionAdapter::BootError)
      chain = []
      current_error = error
      while current_error
        chain << current_error
        current_error = current_error.cause
      end
      chain.each do |link|
        expect(link.message).not_to include(url)
        expect(link.message).not_to include("hunter2secret")
        expect(link.message).not_to include("secret_harness_user")
        expect(link.message).not_to include(token)
        expect(link.message).not_to include("PRIVATE KEY")
      end
      expect(TimekeepingRegressionAdapter.current).to be_nil
      expect(WebMock::Config.instance.allow).to eq(allow_list_before)
      expect(ENV.fetch(Timekeeping::EntryApiClient::BASE_URL_ENV, nil)).to eq("http://outer-before.test")
      expect(ENV.fetch(Timekeeping::UserToken::PRIVATE_KEY_ENV, nil)).to eq("outer-before-key")
    end
  end
end

RSpec.describe "TimekeepingRegressionAdapter cleanup after the instance began", committed_data: true do
  before do
    skip "The suite's own live adapter is running; this example drives start! from a clean state" if TimekeepingRegressionAdapter.current
  end

  # "If anything fails after the instance began, stop it and leave `current` nil. No error message carries the URL,
  # the service token or the private key."
  it "a failure after the live instance began stops it, leaves current nil and leaks no service token" do
    url = "postgresql://after_start_user@127.0.0.1/timekeeping_after_start_test"
    token = "live-service-aftertoken9876543210"
    private_key = OpenSSL::PKey::RSA.generate(2048)
    instance = instance_double(TimekeepingLiveInstance, base_url: "http://127.0.0.1:4999", service_token: token,
                                                        private_key:, stop: nil)
    allow(TimekeepingLiveInstance).to receive(:start).and_return(instance)
    allow_any_instance_of(TimekeepingLiveInstance::ReferenceStub) # rubocop:disable RSpec/AnyInstance
      .to receive(:service_token=).and_raise(RuntimeError, "could not set #{token} for #{url}")
    env = { "TIMEKEEPING_REGRESSION" => "1", "TIMEKEEPING_LIVE" => "1", "TIMEKEEPING_DATABASE_URL" => url }

    with_timekeeping_env(
      Timekeeping::EntryApiClient::BASE_URL_ENV => "http://outer-before.test",
      Timekeeping::UserToken::PRIVATE_KEY_ENV => "outer-before-key"
    ) do
      error = nil
      begin
        TimekeepingRegressionAdapter.start!(env:, owner_state: "timekeeping")
      rescue StandardError => e
        error = e
      end

      expect(error).to be_a(TimekeepingRegressionAdapter::BootError)
      expect(error.message).not_to include(token)
      expect(error.message).not_to include(url)
      expect(error.cause).to be_nil
      expect(instance).to have_received(:stop)
      expect(TimekeepingRegressionAdapter.current).to be_nil
      expect(ENV.fetch(Timekeeping::EntryApiClient::BASE_URL_ENV, nil)).to eq("http://outer-before.test")
      expect(ENV.fetch(Timekeeping::UserToken::PRIVATE_KEY_ENV, nil)).to eq("outer-before-key")
    end
  end
end

RSpec.describe "TimekeepingRegressionAdapter per-example reset, first example", :without_transaction,
               committed_data: true do
  it "with the live adapter running, a first example reaches the live app and leaves a row in the live database" do
    unless ENV["TIMEKEEPING_REGRESSION"] == "1" && ENV["TIMEKEEPING_LIVE"] == "1"
      skip "Set TIMEKEEPING_REGRESSION=1 and TIMEKEEPING_LIVE=1 to run against the live Timekeeping app"
    end
    instance = TimekeepingRegressionAdapter.current
    skip "The live adapter is not running: select the timekeeping owner state and a _test TIMEKEEPING_DATABASE_URL" unless instance

    uri = URI.join(instance.base_url, "/internal/v1/metrics")
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{instance.service_token}"
    response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
    expect(response).to be_a(Net::HTTPOK)

    # The next example in this file checks that the per-example reset removed this row.
    connection = PG.connect(ENV.fetch("TIMEKEEPING_DATABASE_URL"))
    begin
      connection.exec("CREATE TABLE IF NOT EXISTS regression_adapter_reset_probe_rows (id integer)")
      connection.exec("INSERT INTO regression_adapter_reset_probe_rows (id) VALUES (1)")
      expect(connection.exec("SELECT count(*) FROM regression_adapter_reset_probe_rows").getvalue(0, 0).to_i).to eq(1)
    ensure
      connection.close
    end
  end
end

RSpec.describe "TimekeepingRegressionAdapter per-example reset, next example", :without_transaction,
               committed_data: true do
  it "with the live adapter running, the next example reaches the live app and finds the earlier row gone and admission at generation 2" do
    unless ENV["TIMEKEEPING_REGRESSION"] == "1" && ENV["TIMEKEEPING_LIVE"] == "1"
      skip "Set TIMEKEEPING_REGRESSION=1 and TIMEKEEPING_LIVE=1 to run against the live Timekeeping app"
    end
    instance = TimekeepingRegressionAdapter.current
    skip "The live adapter is not running: select the timekeeping owner state and a _test TIMEKEEPING_DATABASE_URL" unless instance

    connection = PG.connect(ENV.fetch("TIMEKEEPING_DATABASE_URL"))
    begin
      probe_exists = connection.exec("SELECT to_regclass('regression_adapter_reset_probe_rows') IS NOT NULL")
                               .getvalue(0, 0) == "t"
      skip "Run this file whole: the example before this one writes the row this one checks" unless probe_exists

      # "Each example starts with the live Timekeeping database reset by `TimekeepingDatabaseReset.reset!` on the checked URL only; rows from one example are absent in the next"
      expect(connection.exec("SELECT count(*) FROM regression_adapter_reset_probe_rows").getvalue(0, 0).to_i).to eq(0)
      # The reset for the timekeeping state leaves one admission row at generation 2.
      expect(connection.exec("SELECT generation FROM admission").to_a).to eq([{ "generation" => "2" }])

      uri = URI.join(instance.base_url, "/internal/v1/metrics")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{instance.service_token}"
      response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
      # "two consecutive examples both reach the live app, and WebMock still blocks any other host"
      expect(response).to be_a(Net::HTTPOK)
    ensure
      connection.exec("DROP TABLE IF EXISTS regression_adapter_reset_probe_rows")
      connection.close
    end
  end
end

RSpec.describe "TimekeepingRegressionAdapter refusing a non-test database", committed_data: true do
  # "A URL whose libpq name ends in \_test but whose Active Record name does not is refused before db:prepare.
  # Use the vector `postgresql://harness_selector_user@127.0.0.1/timekeeping_development?dbname=timekeeping_selector_test`;
  # `TimekeepingLiveInstance.start` is never called."
  it "start! refuses a URL whose Active Record name does not end in _test before starting the instance" do
    skip "The suite's own live adapter is running; this example drives start! from a clean state" if TimekeepingRegressionAdapter.current

    allow(TimekeepingLiveInstance).to receive(:start)
    allow_list_before = Array(WebMock::Config.instance.allow).dup
    env = {
      "TIMEKEEPING_REGRESSION" => "1",
      "TIMEKEEPING_LIVE" => "1",
      "TIMEKEEPING_DATABASE_URL" =>
        "postgresql://harness_selector_user@127.0.0.1/timekeeping_development?dbname=timekeeping_selector_test"
    }

    expect { TimekeepingRegressionAdapter.start!(env:, owner_state: "timekeeping") }
      .to raise_error(TestDatabaseGuard::NotATestDatabase)

    expect(TimekeepingLiveInstance).not_to have_received(:start)
    expect(Array(WebMock::Config.instance.allow)).to eq(allow_list_before)
    expect(TimekeepingRegressionAdapter.current).to be_nil
  end
end

RSpec.describe "TimekeepingRegressionAdapter start gate", committed_data: true do
  # "`start!` returns nil unless `env["TIMEKEEPING_REGRESSION"] == "1"`, `env["TIMEKEEPING_LIVE"] == "1"` and
  # `owner_state == "timekeeping"`."
  it "start! returns nil and starts nothing for rollback, legacy or a missing flag" do
    skip "The suite's own live adapter is running; this example drives start! from a clean state" if TimekeepingRegressionAdapter.current

    allow(TimekeepingLiveInstance).to receive(:start)
    url = { "TIMEKEEPING_DATABASE_URL" => "postgresql://gate_user@127.0.0.1/timekeeping_gate_test" }
    both_flags = { "TIMEKEEPING_REGRESSION" => "1", "TIMEKEEPING_LIVE" => "1" }
    cases = [
      [both_flags.merge(url), "rollback"],
      [both_flags.merge(url), "legacy"],
      [{ "TIMEKEEPING_LIVE" => "1" }.merge(url), "timekeeping"],
      [{ "TIMEKEEPING_REGRESSION" => "true", "TIMEKEEPING_LIVE" => "1" }.merge(url), "timekeeping"],
      [{ "TIMEKEEPING_REGRESSION" => "1" }.merge(url), "timekeeping"],
      [{ "TIMEKEEPING_REGRESSION" => "1", "TIMEKEEPING_LIVE" => "" }.merge(url), "timekeeping"]
    ]

    cases.each do |env, owner_state|
      expect(TimekeepingRegressionAdapter.start!(env:, owner_state:)).to be_nil
      expect(TimekeepingRegressionAdapter.current).to be_nil
    end
    expect(TimekeepingLiveInstance).not_to have_received(:start)
  end
end

RSpec.describe "TimekeepingRegressionAdapter failed start", committed_data: true do
  # "If anything fails after the instance began, stop it and leave `current` nil. No error message carries the URL,
  # the service token or the private key."
  it "a failed live instance start leaves current nil and the error carries no URL, token or key" do
    skip "The suite's own live adapter is running; this example drives start! from a clean state" if TimekeepingRegressionAdapter.current

    checked_url = "postgresql://failing_user:failing-secret@127.0.0.1/timekeeping_failing_test"
    token = "live-service-failing-token"
    pem = OpenSSL::PKey::RSA.generate(2048).to_pem
    allow(TimekeepingLiveInstance).to receive(:start)
      .and_raise(TimekeepingLiveInstance::BootError, "db:prepare failed:\n#{checked_url}\n#{token}\n#{pem}")
    base_url_env = Timekeeping::EntryApiClient::BASE_URL_ENV
    key_env = Timekeeping::UserToken::PRIVATE_KEY_ENV
    env_before = { base_url_env => ENV.fetch(base_url_env, nil), key_env => ENV.fetch(key_env, nil) }
    allow_list_before = Array(WebMock::Config.instance.allow).dup
    env = { "TIMEKEEPING_REGRESSION" => "1", "TIMEKEEPING_LIVE" => "1", "TIMEKEEPING_DATABASE_URL" => checked_url }

    raised = nil
    begin
      TimekeepingRegressionAdapter.start!(env:, owner_state: "timekeeping")
    rescue StandardError => e
      raised = e
    end

    expect(raised).to be_a(TimekeepingRegressionAdapter::BootError)
    error = raised
    while error
      expect(error.message).not_to include(checked_url)
      expect(error.message).not_to include("failing-secret")
      expect(error.message).not_to include(token)
      expect(error.message).not_to include("PRIVATE KEY")
      error = error.cause
    end
    expect(TimekeepingRegressionAdapter.current).to be_nil
    expect(ENV.fetch(base_url_env, nil)).to eq(env_before[base_url_env])
    expect(ENV.fetch(key_env, nil)).to eq(env_before[key_env])
    expect(Array(WebMock::Config.instance.allow)).to eq(allow_list_before)
  end
end

RSpec.describe "TimekeepingRegressionAdapter during live examples", committed_data: true do
  # "Live-gated (skip with a stated reason without the flags and a \_test URL): two consecutive examples both reach
  # the live app; WebMock still blocks any other host, including 127.0.0.1 on another port
  # (`WebMock::NetConnectNotAllowedError`)."
  it "with the live adapter running, examples reach the live app and WebMock blocks 127.0.0.1 on another port" do
    unless ENV["TIMEKEEPING_LIVE"] == "1" && ENV["TIMEKEEPING_REGRESSION"] == "1"
      skip "Set TIMEKEEPING_LIVE=1, TIMEKEEPING_REGRESSION=1 and TIMEKEEPING_OWNER_STATE=timekeeping to run the live adapter"
    end
    skip "Set TIMEKEEPING_DATABASE_URL to a _test database so the live adapter starts" unless TimekeepingRegressionAdapter.current

    live = TimekeepingRegressionAdapter.current
    live_uri = URI.join(live.base_url, "/internal/v1/metrics")
    2.times do
      request = Net::HTTP::Get.new(live_uri)
      request["Authorization"] = "Bearer #{live.service_token}"
      response = Net::HTTP.start(live_uri.host, live_uri.port) { |http| http.request(request) }
      expect(response.code).to eq("200")
    end

    probe = TCPServer.new("127.0.0.1", 0)
    other_port = probe.addr[1]
    probe.close
    expect { Net::HTTP.get(URI("http://127.0.0.1:#{other_port}/")) }.to raise_error(WebMock::NetConnectNotAllowedError)
    expect { Net::HTTP.get(URI("http://example.com/")) }.to raise_error(WebMock::NetConnectNotAllowedError)
  end
end

RSpec.describe TimekeepingRegressionAdapter, committed_data: true do
  # "two consecutive examples both reach the live app, and WebMock still blocks any other host"
  # spec/rails_helper.rb's around hook calls WebMock.disable_net_connect! after every example, so this
  # example can reach the live app only if the adapter's config.before re-allowed its address first.
  it "a later example still reaches the live app after the around hook disabled net connect" do
    instance = described_class.current
    skip "needs TIMEKEEPING_LIVE=1, TIMEKEEPING_REGRESSION=1, the timekeeping owner state and a _test TIMEKEEPING_DATABASE_URL" unless instance

    uri = URI(instance.base_url)
    response = nil
    expect { response = Net::HTTP.get_response(URI.join(instance.base_url, "/up")) }.not_to raise_error
    expect(response).to be_a(Net::HTTPResponse)
    expect(uri.host).to eq("127.0.0.1")
    expect(ENV.fetch(Timekeeping::EntryApiClient::BASE_URL_ENV)).to eq(instance.base_url)
    expect(WebMock::Config.instance.allow).to eq(["127.0.0.1:#{uri.port}"])
  end
end

RSpec.describe "TimekeepingRegressionAdapter start guards", committed_data: true do
  before do
    if TimekeepingRegressionAdapter.current
      skip "The suite's live adapter is running; these examples drive start! from a stopped adapter"
    end
  end

  # "adapter start with TIMEKEEPING_DATABASE_URL unset raises and boots nothing"
  # "Spies show `TimekeepingLiveInstance.start` and `Puma::Server.new` never called, the WebMock allow list and
  # both env keys unchanged, and `current` nil."
  it "start! with TIMEKEEPING_DATABASE_URL missing from env raises BootError naming only the key and boots nothing" do
    allow(TimekeepingLiveInstance).to receive(:start)
    allow(Puma::Server).to receive(:new).and_call_original
    allow_list_before = WebMock::Config.instance.allow.dup
    base_url_before = ENV.fetch(Timekeeping::EntryApiClient::BASE_URL_ENV, nil)
    key_before = ENV.fetch(Timekeeping::UserToken::PRIVATE_KEY_ENV, nil)
    env = { "TIMEKEEPING_REGRESSION" => "1", "TIMEKEEPING_LIVE" => "1" }

    expect { TimekeepingRegressionAdapter.start!(env:, owner_state: "timekeeping") }
      .to raise_error(TimekeepingRegressionAdapter::BootError, /TIMEKEEPING_DATABASE_URL/)

    expect(TimekeepingLiveInstance).not_to have_received(:start)
    expect(Puma::Server).not_to have_received(:new)
    expect(WebMock::Config.instance.allow).to eq(allow_list_before)
    expect(ENV.fetch(Timekeeping::EntryApiClient::BASE_URL_ENV, nil)).to eq(base_url_before)
    expect(ENV.fetch(Timekeeping::UserToken::PRIVATE_KEY_ENV, nil)).to eq(key_before)
    expect(TimekeepingRegressionAdapter.current).to be_nil
  end
end

RSpec.describe "TimekeepingRegressionAdapter mixed database names", committed_data: true do
  before do
    if TimekeepingRegressionAdapter.current
      skip "The suite's live adapter is running; these examples drive start! from a stopped adapter"
    end
  end

  # "A URL whose libpq name ends in \_test but whose Active Record name does not is refused before db:prepare."
  it "start! refuses a URL whose libpq name ends in _test but whose Active Record name does not, before the instance or WebMock is touched" do
    allow(TimekeepingLiveInstance).to receive(:start)
    allow_list_before = WebMock::Config.instance.allow.dup
    url = "postgresql://harness_selector_user@127.0.0.1/timekeeping_development?dbname=timekeeping_selector_test"
    env = { "TIMEKEEPING_REGRESSION" => "1", "TIMEKEEPING_LIVE" => "1", "TIMEKEEPING_DATABASE_URL" => url }

    expect { TimekeepingRegressionAdapter.start!(env:, owner_state: "timekeeping") }
      .to raise_error(TestDatabaseGuard::NotATestDatabase) { |error| expect(error.message).not_to include(url) }

    expect(TimekeepingLiveInstance).not_to have_received(:start)
    expect(WebMock::Config.instance.allow).to eq(allow_list_before)
    expect(TimekeepingRegressionAdapter.current).to be_nil
  end
end

RSpec.describe "TimekeepingRegressionAdapter failed instance start", committed_data: true do
  before do
    if TimekeepingRegressionAdapter.current
      skip "The suite's live adapter is running; these examples drive start! from a stopped adapter"
    end
  end

  # "If anything fails after the instance began, stop it and leave `current` nil. No error message carries the URL,
  # the service token or the private key."
  it "start! whose instance start fails with a message holding the URL, token and key raises a BootError without them and restores WebMock, env and current" do
    url = "postgresql://adapter_secret_user:adapter-secret-password@127.0.0.1/timekeeping_adapter_test"
    token = "live-service-adapter-secret-token"
    pem = "-----BEGIN PRIVATE KEY-----adaptersecretkey-----END PRIVATE KEY-----"
    leaky = TimekeepingLiveInstance::BootError.new("db:prepare failed:\n#{url}\n#{token}\n#{pem}")
    allow(TimekeepingLiveInstance).to receive(:start).and_raise(leaky)
    allow_list_before = WebMock::Config.instance.allow.dup
    base_url_before = ENV.fetch(Timekeeping::EntryApiClient::BASE_URL_ENV, nil)
    key_before = ENV.fetch(Timekeeping::UserToken::PRIVATE_KEY_ENV, nil)
    env = { "TIMEKEEPING_REGRESSION" => "1", "TIMEKEEPING_LIVE" => "1", "TIMEKEEPING_DATABASE_URL" => url }

    raised = nil
    begin
      TimekeepingRegressionAdapter.start!(env:, owner_state: "timekeeping")
    rescue StandardError => error
      raised = error
    end

    expect(raised).to be_a(TimekeepingRegressionAdapter::BootError)
    chain = []
    current_error = raised
    while current_error
      chain << current_error.message
      current_error = current_error.cause
    end
    chain.each do |message|
      expect(message).not_to include(url)
      expect(message).not_to include("adapter-secret-password")
      expect(message).not_to include(token)
      expect(message).not_to include("PRIVATE KEY")
    end
    expect(TimekeepingRegressionAdapter.current).to be_nil
    expect(WebMock::Config.instance.allow).to eq(allow_list_before)
    expect(ENV.fetch(Timekeeping::EntryApiClient::BASE_URL_ENV, nil)).to eq(base_url_before)
    expect(ENV.fetch(Timekeeping::UserToken::PRIVATE_KEY_ENV, nil)).to eq(key_before)
  end
end

RSpec.describe "TimekeepingRegressionAdapter failure after the instance began", committed_data: true do
  before do
    if TimekeepingRegressionAdapter.current
      skip "The suite's live adapter is running; these examples drive start! from a stopped adapter"
    end
  end

  # "If anything fails after the instance began, stop it and leave `current` nil."
  it "start! that fails after the instance began stops that instance, leaves current nil and keeps the URL out of the error" do
    url = "postgresql://adapter_late_user@127.0.0.1/timekeeping_adapter_late_test"
    instance = instance_double(TimekeepingLiveInstance, service_token: "live-service-late-token",
                                                        base_url: "http://127.0.0.1:4998",
                                                        private_key: OpenSSL::PKey::RSA.generate(2048),
                                                        stop: nil)
    allow(TimekeepingLiveInstance).to receive(:start).and_return(instance)
    # Setting the reference stub's service token is the step right after the instance starts.
    allow_any_instance_of(TimekeepingLiveInstance::ReferenceStub) # rubocop:disable RSpec/AnyInstance
      .to receive(:service_token=).and_raise(RuntimeError, "could not set token for #{url}")
    allow_list_before = WebMock::Config.instance.allow.dup
    base_url_before = ENV.fetch(Timekeeping::EntryApiClient::BASE_URL_ENV, nil)
    env = { "TIMEKEEPING_REGRESSION" => "1", "TIMEKEEPING_LIVE" => "1", "TIMEKEEPING_DATABASE_URL" => url }

    expect { TimekeepingRegressionAdapter.start!(env:, owner_state: "timekeeping") }
      .to raise_error(TimekeepingRegressionAdapter::BootError) { |error|
        expect(error.message).not_to include(url)
        expect(error.cause).to be_nil
      }

    expect(instance).to have_received(:stop)
    expect(TimekeepingRegressionAdapter.current).to be_nil
    expect(WebMock::Config.instance.allow).to eq(allow_list_before)
    expect(ENV.fetch(Timekeeping::EntryApiClient::BASE_URL_ENV, nil)).to eq(base_url_before)
  end
end

RSpec.describe "TimekeepingRegressionAdapter start gate", committed_data: true do
  before do
    if TimekeepingRegressionAdapter.current
      skip "The suite's live adapter is running; these examples drive start! from a stopped adapter"
    end
  end

  # "`start!` returns nil unless `env["TIMEKEEPING_REGRESSION"] == "1"`, `env["TIMEKEEPING_LIVE"] == "1"` and
  # `owner_state == "timekeeping"`."
  it "start! returns nil and starts nothing for rollback, legacy, an empty state or any flag that is not exactly 1" do
    allow(TimekeepingLiveInstance).to receive(:start)
    allow_list_before = WebMock::Config.instance.allow.dup
    url = "postgresql://harness_user@127.0.0.1/timekeeping_adapter_gate_test"
    full = { "TIMEKEEPING_REGRESSION" => "1", "TIMEKEEPING_LIVE" => "1", "TIMEKEEPING_DATABASE_URL" => url }
    refused = [
      [full, "rollback"],
      [full, "legacy"],
      [full, ""],
      [full, nil],
      [full.except("TIMEKEEPING_REGRESSION"), "timekeeping"],
      [full.merge("TIMEKEEPING_REGRESSION" => "true"), "timekeeping"],
      [full.merge("TIMEKEEPING_REGRESSION" => "0"), "timekeeping"],
      [full.except("TIMEKEEPING_LIVE"), "timekeeping"],
      [full.merge("TIMEKEEPING_LIVE" => ""), "timekeeping"]
    ]

    refused.each do |env, owner_state|
      expect(TimekeepingRegressionAdapter.start!(env:, owner_state:)).to be_nil, "expected nil for #{owner_state.inspect} with #{env.except('TIMEKEEPING_DATABASE_URL')}"
    end

    expect(TimekeepingLiveInstance).not_to have_received(:start)
    expect(WebMock::Config.instance.allow).to eq(allow_list_before)
    expect(TimekeepingRegressionAdapter.current).to be_nil
  end
end

RSpec.describe "TimekeepingRegressionAdapter checked URL", committed_data: true do
  before do
    if TimekeepingRegressionAdapter.current
      skip "The suite's live adapter is running; these examples drive start! from a stopped adapter"
    end
  end

  after do
    TimekeepingRegressionAdapter.stop! if TimekeepingRegressionAdapter.current
    WebMock.disable_net_connect!
  end

  # "A \_test URL given in `env:` reaches `TimekeepingLiveInstance.start` as `database_url:` even when global ENV
  # names another URL."
  it "start! hands the instance the env: URL even when global ENV names a different database" do
    checked = "postgresql://harness_user@127.0.0.1/timekeeping_adapter_checked_test"
    instance = instance_double(TimekeepingLiveInstance, service_token: "live-service-checked-token",
                                                        base_url: "http://127.0.0.1:4997",
                                                        private_key: OpenSSL::PKey::RSA.generate(2048),
                                                        stop: nil)
    allow(TimekeepingLiveInstance).to receive(:start).and_return(instance)
    env = { "TIMEKEEPING_REGRESSION" => "1", "TIMEKEEPING_LIVE" => "1", "TIMEKEEPING_DATABASE_URL" => checked }

    with_timekeeping_env(
      "TIMEKEEPING_DATABASE_URL" => "postgresql://harness_user@127.0.0.1/timekeeping_development",
      Timekeeping::EntryApiClient::BASE_URL_ENV => ENV.fetch(Timekeeping::EntryApiClient::BASE_URL_ENV, nil),
      Timekeeping::UserToken::PRIVATE_KEY_ENV => ENV.fetch(Timekeeping::UserToken::PRIVATE_KEY_ENV, nil)
    ) do
      TimekeepingRegressionAdapter.start!(env:, owner_state: "timekeeping")
      TimekeepingRegressionAdapter.stop!
    end

    expect(TimekeepingLiveInstance).to have_received(:start)
      .once.with(hash_including(database_url: checked, admission_generation: 2))
  end
end
