# frozen_string_literal: true

require "rails_helper"
require "net/http"
require "socket"

RSpec.describe "TimekeepingRegressionAdapter.start! from a stopped adapter", committed_data: true do
  let(:base_url_env) { Timekeeping::EntryApiClient::BASE_URL_ENV }
  let(:key_env) { Timekeeping::UserToken::PRIVATE_KEY_ENV }
  let(:live_flags) { { "TIMEKEEPING_REGRESSION" => "1", "TIMEKEEPING_LIVE" => "1" } }

  before do
    skip "The suite's own live adapter is running; these examples drive start! from a stopped adapter" if TimekeepingRegressionAdapter.current
  end

  # Runs start! with known outer values in both client env keys, so each example can show they are left as they were.
  def start_adapter_with_outer_client_env(env)
    with_timekeeping_env(base_url_env => "http://outer-before.test", key_env => "outer-before-key") do
      TimekeepingRegressionAdapter.start!(env:, owner_state: "timekeeping")
    end
  end

  def expect_outer_client_env_kept
    expect(ENV.fetch(base_url_env, nil)).to eq("http://outer-before.test")
    expect(ENV.fetch(key_env, nil)).to eq("outer-before-key")
  end

  def error_chain(error)
    chain = []
    while error
      chain << error
      error = error.cause
    end
    chain
  end

  # "Ordinary suite: adapter start with TIMEKEEPING_DATABASE_URL unset raises and boots nothing. Spies show
  # `TimekeepingLiveInstance.start` and `Puma::Server.new` never called, the WebMock allow list and both env
  # keys unchanged, and `current` nil."
  it "start! with TIMEKEEPING_DATABASE_URL unset raises BootError naming only the key and boots nothing" do
    allow(TimekeepingLiveInstance).to receive(:start)
    allow(Puma::Server).to receive(:new).and_call_original
    allow_list_before = WebMock::Config.instance.allow.dup
    allow_net_connect_before = WebMock::Config.instance.allow_net_connect

    with_timekeeping_env(base_url_env => "http://outer-before.test", key_env => "outer-before-key") do
      expect { TimekeepingRegressionAdapter.start!(env: live_flags, owner_state: "timekeeping") }
        .to raise_error(TimekeepingRegressionAdapter::BootError, /TIMEKEEPING_DATABASE_URL/)

      expect_outer_client_env_kept
    end
    expect(TimekeepingLiveInstance).not_to have_received(:start)
    expect(Puma::Server).not_to have_received(:new)
    expect(WebMock::Config.instance.allow).to eq(allow_list_before)
    expect(WebMock::Config.instance.allow_net_connect).to eq(allow_net_connect_before)
    expect(TimekeepingRegressionAdapter.current).to be_nil
  end

  # "A URL whose libpq name ends in \_test but whose Active Record name does not is refused before db:prepare.
  # Use the vector `postgresql://harness_selector_user@127.0.0.1/timekeeping_development?dbname=timekeeping_selector_test`;
  # `TimekeepingLiveInstance.start` is never called."
  it "start! refuses a URL whose Active Record name does not end in _test before the live instance starts" do
    allow(TimekeepingLiveInstance).to receive(:start)
    allow(Puma::Server).to receive(:new).and_call_original
    url = "postgresql://harness_selector_user@127.0.0.1/timekeeping_development?dbname=timekeeping_selector_test"
    allow_list_before = WebMock::Config.instance.allow.dup

    expect { TimekeepingRegressionAdapter.start!(env: live_flags.merge("TIMEKEEPING_DATABASE_URL" => url), owner_state: "timekeeping") }
      .to raise_error(TestDatabaseGuard::NotATestDatabase) { |error|
        # "No error message carries the URL, the service token or the private key."
        expect(error.message).not_to include(url)
        expect(error.message).not_to include("harness_selector_user")
      }

    expect(TimekeepingLiveInstance).not_to have_received(:start)
    expect(Puma::Server).not_to have_received(:new)
    expect(WebMock::Config.instance.allow).to eq(allow_list_before)
    expect(TimekeepingRegressionAdapter.current).to be_nil
  end

  # "`start!` returns nil unless `env["TIMEKEEPING_REGRESSION"] == "1"`, `env["TIMEKEEPING_LIVE"] == "1"` and
  # `owner_state == "timekeeping"`."
  it "start! returns nil and starts nothing for rollback, legacy, an empty state or any flag that is not exactly 1" do
    allow(TimekeepingLiveInstance).to receive(:start)
    allow_list_before = WebMock::Config.instance.allow.dup
    full = live_flags.merge("TIMEKEEPING_DATABASE_URL" => "postgresql://harness_user@127.0.0.1/timekeeping_adapter_gate_test")
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
      expect(TimekeepingRegressionAdapter.start!(env:, owner_state:))
        .to be_nil, "expected nil for #{owner_state.inspect} with #{env.except('TIMEKEEPING_DATABASE_URL')}"
      expect(TimekeepingRegressionAdapter.current).to be_nil
    end

    expect(TimekeepingLiveInstance).not_to have_received(:start)
    expect(WebMock::Config.instance.allow).to eq(allow_list_before)
  end

  # "If anything fails after the instance began, stop it and leave `current` nil. No error message carries the URL,
  # the service token or the private key."
  it "a failing live instance start raises a BootError whose cause chain carries no URL, token or key and restores WebMock, env and current" do
    url = "postgresql://adapter_user:adapter-secret-password@127.0.0.1/timekeeping_adapter_test"
    token = "live-service-leakedtoken0123456789"
    pem = OpenSSL::PKey::RSA.generate(2048).to_pem
    # The live instance's own boot errors carry raw child output, which can hold all three.
    allow(TimekeepingLiveInstance).to receive(:start)
      .and_raise(TimekeepingLiveInstance::BootError, "bundle exec rails db:prepare failed:\n#{url}\n#{token}\n#{pem}")
    allow_list_before = WebMock::Config.instance.allow.dup
    allow_net_connect_before = WebMock::Config.instance.allow_net_connect

    error = nil
    with_timekeeping_env(base_url_env => "http://outer-before.test", key_env => "outer-before-key") do
      TimekeepingRegressionAdapter.start!(env: live_flags.merge("TIMEKEEPING_DATABASE_URL" => url), owner_state: "timekeeping")
    rescue StandardError => e
      error = e
      expect_outer_client_env_kept
    end

    expect(error).to be_a(TimekeepingRegressionAdapter::BootError)
    error_chain(error).each do |link|
      expect(link.message).not_to include(url)
      expect(link.message).not_to include("adapter-secret-password")
      expect(link.message).not_to include(token)
      expect(link.message).not_to include("PRIVATE KEY")
    end
    expect(TimekeepingRegressionAdapter.current).to be_nil
    expect(WebMock::Config.instance.allow).to eq(allow_list_before)
    expect(WebMock::Config.instance.allow_net_connect).to eq(allow_net_connect_before)
  end

  # "If anything fails after the instance began, stop it and leave `current` nil."
  it "a failure after the live instance began stops it, leaves current nil, restores WebMock and env and leaks no service token" do
    url = "postgresql://after_start_user@127.0.0.1/timekeeping_after_start_test"
    token = "live-service-aftertoken9876543210"
    instance = instance_double(TimekeepingLiveInstance, base_url: "http://127.0.0.1:4999", service_token: token,
                                                        private_key: OpenSSL::PKey::RSA.generate(2048), stop: nil)
    allow(TimekeepingLiveInstance).to receive(:start).and_return(instance)
    # Setting the reference stub's service token is the step right after the instance starts.
    allow_any_instance_of(TimekeepingLiveInstance::ReferenceStub) # rubocop:disable RSpec/AnyInstance
      .to receive(:service_token=).and_raise(RuntimeError, "could not set #{token} for #{url}")
    allow_list_before = WebMock::Config.instance.allow.dup

    error = nil
    with_timekeeping_env(base_url_env => "http://outer-before.test", key_env => "outer-before-key") do
      TimekeepingRegressionAdapter.start!(env: live_flags.merge("TIMEKEEPING_DATABASE_URL" => url), owner_state: "timekeeping")
    rescue StandardError => e
      error = e
      expect_outer_client_env_kept
    end

    expect(error).to be_a(TimekeepingRegressionAdapter::BootError)
    expect(error.message).not_to include(token)
    expect(error.message).not_to include(url)
    expect(error.cause).to be_nil
    expect(instance).to have_received(:stop)
    expect(TimekeepingRegressionAdapter.current).to be_nil
    expect(WebMock::Config.instance.allow).to eq(allow_list_before)
  end

  # "If anything fails after the instance began, stop it and leave `current` nil."
  it "a failure while writing the private key, after the base URL was written, restores both client env keys and stops the instance" do
    url = "postgresql://partial_env_user@127.0.0.1/timekeeping_partial_env_test"
    private_key = OpenSSL::PKey::RSA.generate(2048)
    instance = instance_double(TimekeepingLiveInstance, base_url: "http://127.0.0.1:4996", service_token: "live-service-partial",
                                                        private_key:, stop: nil)
    allow(TimekeepingLiveInstance).to receive(:start).and_return(instance)
    allow(ENV).to receive(:[]=).and_call_original
    allow(ENV).to receive(:[]=).with(key_env, private_key.to_pem).and_raise(RuntimeError, "could not write the key")
    allow_list_before = WebMock::Config.instance.allow.dup

    error = nil
    with_timekeeping_env(base_url_env => "http://outer-before.test", key_env => "outer-before-key") do
      TimekeepingRegressionAdapter.start!(env: live_flags.merge("TIMEKEEPING_DATABASE_URL" => url), owner_state: "timekeeping")
    rescue StandardError => e
      error = e
      expect_outer_client_env_kept
    end

    expect(ENV).to have_received(:[]=).with(base_url_env, "http://127.0.0.1:4996")
    expect(error).to be_a(TimekeepingRegressionAdapter::BootError)
    expect(error.cause).to be_nil
    expect(instance).to have_received(:stop)
    expect(TimekeepingRegressionAdapter.current).to be_nil
    expect(WebMock::Config.instance.allow).to eq(allow_list_before)
  end

  # "No error message carries the URL, the service token or the private key."
  it "a failed start whose instance also fails to stop still raises the clean BootError and restores WebMock and env" do
    url = "postgresql://stop_fails_user@127.0.0.1/timekeeping_stop_fails_test"
    token = "live-service-stopfails0123456789"
    instance = instance_double(TimekeepingLiveInstance, base_url: "http://127.0.0.1:4995", service_token: token,
                                                        private_key: OpenSSL::PKey::RSA.generate(2048))
    allow(instance).to receive(:stop).and_raise(IOError, "shutdown failed for #{url}")
    allow(TimekeepingLiveInstance).to receive(:start).and_return(instance)
    allow_any_instance_of(TimekeepingLiveInstance::ReferenceStub) # rubocop:disable RSpec/AnyInstance
      .to receive(:service_token=).and_raise(RuntimeError, "startup failed with #{token} for #{url}")
    allow_list_before = WebMock::Config.instance.allow.dup
    allow_net_connect_before = WebMock::Config.instance.allow_net_connect

    error = nil
    with_timekeeping_env(base_url_env => "http://outer-before.test", key_env => "outer-before-key") do
      TimekeepingRegressionAdapter.start!(env: live_flags.merge("TIMEKEEPING_DATABASE_URL" => url), owner_state: "timekeeping")
    rescue StandardError => e
      error = e
      expect_outer_client_env_kept
    end

    expect(error).to be_a(TimekeepingRegressionAdapter::BootError)
    expect(error.cause).to be_nil
    expect(error.message).not_to include(url)
    expect(error.message).not_to include(token)
    expect(instance).to have_received(:stop)
    expect(TimekeepingRegressionAdapter.current).to be_nil
    expect(WebMock::Config.instance.allow).to eq(allow_list_before)
    expect(WebMock::Config.instance.allow_net_connect).to eq(allow_net_connect_before)
  end

  # "A \_test URL given in `env:` reaches `TimekeepingLiveInstance.start` as `database_url:` even when global ENV
  # names another URL."
  it "start! passes the env: test URL to the live instance once, allows only its port and points the client at it" do
    saved = [base_url_env, key_env, "TIMEKEEPING_DATABASE_URL"].index_with { |name| ENV.fetch(name, nil) }
    key = OpenSSL::PKey::RSA.generate(2048)
    received = nil
    instance = nil
    allow(TimekeepingLiveInstance).to receive(:start) do |**keywords|
      received = keywords
      instance = double("live instance", base_url: "http://127.0.0.1:#{keywords[:port]}", private_key: key,
                                         service_token: "adapter-success-token", admission_generation: 2, stop: nil)
    end
    checked_url = "postgresql://adapter_user@127.0.0.1/timekeeping_adapter_test"

    begin
      ENV["TIMEKEEPING_DATABASE_URL"] = "postgresql://other_user@127.0.0.1/timekeeping_other_test"
      started = TimekeepingRegressionAdapter.start!(env: live_flags.merge("TIMEKEEPING_DATABASE_URL" => checked_url),
                                                    owner_state: "timekeeping")

      expect(TimekeepingLiveInstance).to have_received(:start).once
      expect(received).to include(database_url: checked_url, admission_generation: 2)
      expect(received[:port]).to be_a(Integer)
      expect(received[:reference_stub].service_token).to eq("adapter-success-token")
      # "set the two env keys; store the instance as `current`"
      expect(started).to be(instance)
      expect(TimekeepingRegressionAdapter.current).to be(instance)
      # The forwarded helpers open the live database with this URL, so it must
      # be the one start! checked, not the global ENV value.
      expect(TimekeepingRegressionAdapter.database_url).to eq(checked_url)
      expect(Array(WebMock::Config.instance.allow)).to eq(["127.0.0.1:#{received[:port]}"])
      expect(ENV.fetch(base_url_env, nil)).to eq("http://127.0.0.1:#{received[:port]}")
      expect(ENV.fetch(key_env, nil)).to eq(key.to_pem)

      # "The `config.before` passes `{ "TIMEKEEPING_DATABASE_URL" => <checked url> }` as the reset's `env:`, so the
      # reset also opens only the checked URL."
      allow(TimekeepingDatabaseReset).to receive(:reset!)
      # System and feature specs start with every connection allowed; the restriction must replace that too.
      WebMock.allow_net_connect!
      TimekeepingRegressionAdapter.prepare_example!(RSpec.current_example)
      expect(WebMock::Config.instance.allow_net_connect).to be(false)
      expect(Array(WebMock::Config.instance.allow)).to eq(["127.0.0.1:#{received[:port]}"])
      expect(TimekeepingDatabaseReset).to have_received(:reset!)
        .once.with("timekeeping", env: { "TIMEKEEPING_DATABASE_URL" => checked_url })
    ensure
      TimekeepingRegressionAdapter.stop!
      saved.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    end
    # "An `after(:suite)` hook stops the instance."
    expect(instance).to have_received(:stop)
    expect(TimekeepingRegressionAdapter.current).to be_nil
    expect(TimekeepingRegressionAdapter.database_url).to be_nil
  end
end

# "Live-gated (skip with a stated reason without the flags and a \_test URL): two consecutive examples both reach
# the live app; WebMock still blocks any other host, including 127.0.0.1 on another port
# (`WebMock::NetConnectNotAllowedError`)." The two examples run in file order, the first writing a row the
# second must not see.
RSpec.describe "TimekeepingRegressionAdapter during live examples", :without_transaction, committed_data: true do
  let(:live_instance) { TimekeepingRegressionAdapter.current }

  before do
    unless ENV["TIMEKEEPING_REGRESSION"] == "1" && ENV["TIMEKEEPING_LIVE"] == "1"
      skip "Set TIMEKEEPING_REGRESSION=1 and TIMEKEEPING_LIVE=1 to run against the live Timekeeping app"
    end
    skip "The live adapter is not running: select the timekeeping owner state and a _test TIMEKEEPING_DATABASE_URL" unless live_instance
  end

  def live_metrics_response
    uri = URI.join(live_instance.base_url, "/internal/v1/metrics")
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{live_instance.service_token}"
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
  end

  it "with the live adapter running, a first example reaches the live app and leaves a row in the live database" do
    expect(live_metrics_response).to be_a(Net::HTTPOK)

    connection = PG.connect(ENV.fetch("TIMEKEEPING_DATABASE_URL"))
    begin
      connection.exec("CREATE TABLE IF NOT EXISTS regression_adapter_reset_probe_rows (id integer)")
      connection.exec("INSERT INTO regression_adapter_reset_probe_rows (id) VALUES (1)")
      expect(connection.exec("SELECT count(*) FROM regression_adapter_reset_probe_rows").getvalue(0, 0).to_i).to eq(1)
    ensure
      connection.close
    end
  end

  # spec/rails_helper.rb's around hook calls WebMock.disable_net_connect! after every example, so this example
  # reaches the live app only if the adapter's config.before re-allowed its address first.
  it "with the live adapter running, the next example reaches the live app, finds the earlier row gone and WebMock blocks every other address" do
    2.times { expect(live_metrics_response).to be_a(Net::HTTPOK) }
    live_uri = URI(live_instance.base_url)
    expect(live_uri.host).to eq("127.0.0.1")
    expect(ENV.fetch(Timekeeping::EntryApiClient::BASE_URL_ENV)).to eq(live_instance.base_url)
    expect(WebMock::Config.instance.allow).to eq(["127.0.0.1:#{live_uri.port}"])

    probe = TCPServer.new("127.0.0.1", 0)
    other_port = probe.addr[1]
    probe.close
    expect { Net::HTTP.get(URI("http://127.0.0.1:#{other_port}/")) }.to raise_error(WebMock::NetConnectNotAllowedError)
    expect { Net::HTTP.get(URI("http://example.com/")) }.to raise_error(WebMock::NetConnectNotAllowedError)

    # The network checks above run first, so running this example alone skips only the reset check below.
    connection = PG.connect(ENV.fetch("TIMEKEEPING_DATABASE_URL"))
    begin
      probe_exists = connection.exec("SELECT to_regclass('regression_adapter_reset_probe_rows') IS NOT NULL")
                               .getvalue(0, 0) == "t"
      skip "Run this file whole: the example before this one writes the row this one checks" unless probe_exists

      # "Each example starts with the live Timekeeping database reset by `TimekeepingDatabaseReset.reset!` on the checked URL only; rows from one example are absent in the next"
      expect(connection.exec("SELECT count(*) FROM regression_adapter_reset_probe_rows").getvalue(0, 0).to_i).to eq(0)
      # The reset for the timekeeping state leaves one admission row at generation 2.
      expect(connection.exec("SELECT generation FROM admission").to_a).to eq([{ "generation" => "2" }])
    ensure
      connection.exec("DROP TABLE IF EXISTS regression_adapter_reset_probe_rows")
      connection.close
    end
  end
end
