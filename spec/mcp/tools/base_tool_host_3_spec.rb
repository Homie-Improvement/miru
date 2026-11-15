# frozen_string_literal: true

require "rails_helper"

RSpec.describe "MCP tool proxied request identity" do
  let(:sent_requests) { [] }

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
      sent_requests << { host: options["HTTP_HOST"], authorization: options["HTTP_AUTHORIZATION"] }
      Rack::MockResponse.new(200, { "content-type" => "application/json" }, "{}")
    end
  end

  # The company a tool call acts on comes from the caller's token, so removing the
  # request Host must leave that token exactly as the caller sent it.
  it "whoami tool call keeps the caller's own bearer token and sends the configured host, not the server context host" do
    # "A BaseTool invocation whose server_context host differs from AppBaseUrl.current sends the configured host, not the request host, as HTTP_HOST in the internal Rack request."
    MCP::Miru::Tools::WorkspaceWhoamiTool.call(
      server_context: { authorization: "Bearer tenant-a-token", host: "tenant-b.example.com" }
    )

    expect(sent_requests).to eq([{ host: "configured-host.test", authorization: "Bearer tenant-a-token" }])
  end
end
