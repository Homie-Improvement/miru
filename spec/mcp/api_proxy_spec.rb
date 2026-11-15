# frozen_string_literal: true

require "rails_helper"

RSpec.describe MCP::Miru::ApiProxy do
  describe "Host header" do
    let(:sent_hosts) { [] }

    around do |example|
      with_app_base_url(env: nil, default: "https://boot-check.test") { example.run }
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
