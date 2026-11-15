# frozen_string_literal: true

require "rails_helper"

RSpec.describe MCP::Miru::ApiProxy do
  describe "Host header" do
    let(:sent_hosts) { [] }

    around do |example|
      original_app_base_url = ENV["APP_BASE_URL"]
      original_default_base_url = Rails.configuration.x.default_base_url
      example.run
    ensure
      original_app_base_url.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original_app_base_url
      Rails.configuration.x.default_base_url = original_default_base_url
    end

    before do
      allow_any_instance_of(Rack::MockRequest).to receive(:request) do |_mock, _verb, _path, options|
        sent_hosts << options["HTTP_HOST"]
        Rack::MockResponse.new(200, { "content-type" => "application/json" }, "{}")
      end
    end

    def proxy_get
      described_class.request(method: :get, path: "/api/v1/clients", authorization: "Bearer token")
    end

    it "sends the host and non-default port of the swapped config.x.default_base_url when APP_BASE_URL is unset" do
      ENV.delete("APP_BASE_URL")

      Rails.configuration.x.default_base_url = "https://boot-check.test"
      proxy_get
      Rails.configuration.x.default_base_url = "http://boot-check.test:4000"
      proxy_get

      expect(sent_hosts).to eq(["boot-check.test", "boot-check.test:4000"])
    end

    # Before this change a blank APP_BASE_URL sent no Host at all.
    it "sends the config.x.default_base_url host with its port when APP_BASE_URL is blank" do
      ENV["APP_BASE_URL"] = ""
      Rails.configuration.x.default_base_url = "http://boot-check.test:4000"

      proxy_get

      expect(sent_hosts).to eq(["boot-check.test:4000"])
    end

    it "sends the host and port of a set APP_BASE_URL ahead of config.x.default_base_url" do
      ENV["APP_BASE_URL"] = "https://app.miru.so:8443"
      Rails.configuration.x.default_base_url = "https://boot-check.test"

      proxy_get

      expect(sent_hosts).to eq(["app.miru.so:8443"])
    end
  end
end

RSpec.describe MCP::Miru::ApiProxy do
  it "refuses caller-supplied headers so no caller can replace the configured Host" do
    sent_hosts = []
    allow_any_instance_of(Rack::MockRequest).to receive(:request) do |_mock, _verb, _path, options|
      sent_hosts << options["HTTP_HOST"]
      Rack::MockResponse.new(200, { "content-type" => "application/json" }, "{}")
    end

    expect {
      described_class.request(
        method: :get, path: "/api/v1/users/_me", authorization: "Bearer token", headers: { "Host" => "attacker.test" }
      )
    }.to raise_error(ArgumentError)
    expect(sent_hosts).to be_empty
  end
end

require "rails_helper"

RSpec.describe MCP::Miru::ApiProxy do
  before do
    allow_any_instance_of(Rack::MockRequest).to receive(:request) do
      Rack::MockResponse.new(200, { "content-type" => "application/json" }, "{}")
    end
  end

  it "rejects a caller-supplied headers keyword so no caller can replace the configured Host" do
    expect {
      described_class.request(
        method: :get, path: "/api/v1/clients", authorization: "Bearer token", headers: { "Host" => "evil.test" }
      )
    }.to raise_error(ArgumentError)
  end
end

require "rails_helper"

RSpec.describe MCP::Miru::ApiProxy do
  it "refuses a caller-supplied headers keyword so no caller can replace the configured Host" do
    expect do
      described_class.request(
        method: :get, path: "/api/v1/clients", authorization: "Bearer token", headers: { "Host" => "evil.test" }
      )
    end.to raise_error(ArgumentError, /headers/)
  end
end

require "rails_helper"

RSpec.describe MCP::Miru::ApiProxy do
  let(:proxy_hosts_seen_by_override_check) { [] }

  around do |example|
    original_app_base_url = ENV["APP_BASE_URL"]
    original_default_base_url = Rails.configuration.x.default_base_url
    ENV.delete("APP_BASE_URL")
    Rails.configuration.x.default_base_url = "https://configured-host.test"
    example.run
  ensure
    original_app_base_url.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original_app_base_url
    Rails.configuration.x.default_base_url = original_default_base_url
  end

  before do
    allow_any_instance_of(Rack::MockRequest).to receive(:request) do |_mock, _verb, _path, options|
      proxy_hosts_seen_by_override_check << options["HTTP_HOST"]
      Rack::MockResponse.new(200, { "content-type" => "application/json" }, "{}")
    end
  end

  # A caller that passes its own Host must not be able to replace the configured one, so the
  # proxy no longer accepts request headers at all.
  it "refuses a caller-supplied Host header instead of letting it replace the configured host" do
    expect {
      described_class.request(
        method: :get, path: "/api/v1/users/_me", authorization: "Bearer token",
        headers: { "Host" => "attacker.test" }
      )
    }.to raise_error(ArgumentError)

    expect(proxy_hosts_seen_by_override_check).to be_empty
  end
end
