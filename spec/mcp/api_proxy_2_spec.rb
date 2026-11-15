# frozen_string_literal: true

require "rails_helper"

RSpec.describe MCP::Miru::ApiProxy do
  # Acceptance: "app/mcp/api_proxy.rb ... no longer carry their own APP_BASE_URL fallback literals;
  # each reads the one per-environment base URL (APP_BASE_URL, else config.x.default_base_url)."
  # Today a blank APP_BASE_URL sends no Host at all.
  it "sends the config.x.default_base_url host with its port when APP_BASE_URL is blank" do
    original_app_base_url = ENV["APP_BASE_URL"]
    original_default_base_url = Rails.configuration.x.default_base_url
    ENV["APP_BASE_URL"] = ""
    Rails.configuration.x.default_base_url = "http://boot-check.test:4000"
    sent_options = nil
    allow_any_instance_of(Rack::MockRequest).to receive(:request) do |_mock, _method, _path, options|
      sent_options = options
      Rack::MockResponse.new(200, { "content-type" => "application/json" }, "{}")
    end

    described_class.request(method: :get, path: "/api/v1/users", authorization: "Bearer token")

    expect(sent_options["HTTP_HOST"]).to eq("boot-check.test:4000")
  ensure
    original_app_base_url.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original_app_base_url
    Rails.configuration.x.default_base_url = original_default_base_url
  end
end
