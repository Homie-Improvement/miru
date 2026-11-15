require "rails_helper"

RSpec.describe MCP::Miru::ApiProxy do
  # "app/services/quick_books/configuration.rb, app/mcp/api_proxy.rb and the mailers no longer carry their own
  # APP_BASE_URL fallback literals; each reads the one per-environment base URL (APP_BASE_URL, else config.x.default_base_url)."
  it "sends the host and non-default port of the swapped config.x.default_base_url when APP_BASE_URL is unset" do
    original_app_base_url = ENV["APP_BASE_URL"]
    original_default_base_url = Rails.configuration.x.default_base_url
    ENV.delete("APP_BASE_URL")
    sent_hosts = []
    allow_any_instance_of(Rack::MockRequest).to receive(:request) do |_mock, _verb, _path, options|
      sent_hosts << options["HTTP_HOST"]
      Rack::MockResponse.new(200, {}, "{}")
    end

    Rails.configuration.x.default_base_url = "https://boot-check.test"
    described_class.request(method: :get, path: "/api/v1/clients", authorization: "Bearer token")
    Rails.configuration.x.default_base_url = "http://boot-check.test:4000"
    described_class.request(method: :get, path: "/api/v1/clients", authorization: "Bearer token")

    expect(sent_hosts).to eq(["boot-check.test", "boot-check.test:4000"])
  ensure
    original_app_base_url.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original_app_base_url
    Rails.configuration.x.default_base_url = original_default_base_url
  end
end

require "rails_helper"

RSpec.describe MCP::Miru::ApiProxy do
  # "each reads the one per-environment base URL (APP_BASE_URL, else config.x.default_base_url)."
  it "sends the host and port of a set APP_BASE_URL ahead of config.x.default_base_url" do
    original_default = Rails.configuration.x.default_base_url
    original_env = ENV["APP_BASE_URL"]
    ENV["APP_BASE_URL"] = "https://app.miru.so:8443"
    Rails.configuration.x.default_base_url = "https://boot-check.test"
    sent_env = nil
    allow_any_instance_of(Rack::MockRequest).to receive(:request) do |_mock, _method, _path, options|
      sent_env = options
      Rack::MockResponse.new(200, { "content-type" => "application/json" }, ["{}"])
    end

    described_class.request(method: :get, path: "/api/v1/clients", authorization: "Bearer token")

    expect(sent_env["HTTP_HOST"]).to eq("app.miru.so:8443")
  ensure
    Rails.configuration.x.default_base_url = original_default
    original_env.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original_env
  end
end
