# frozen_string_literal: true

require "rails_helper"

RSpec.describe "MCP tool proxied Host" do
  let(:sent_requests) { [] }

  around do |example|
    original_app_base_url = ENV["APP_BASE_URL"]
    original_default_base_url = Rails.configuration.x.default_base_url
    ENV.delete("APP_BASE_URL")
    Rails.configuration.x.default_base_url = "https://configured-host.test"
    Rails.cache.clear
    example.run
  ensure
    original_app_base_url.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original_app_base_url
    Rails.configuration.x.default_base_url = original_default_base_url
    Rails.cache.clear
  end

  before do
    allow_any_instance_of(Rack::MockRequest).to receive(:request) do |_mock, _verb, _path, options|
      sent_requests << options
      Rack::MockResponse.new(200, { "content-type" => "application/json" }, "{}")
    end
  end

  # "A BaseTool invocation whose server_context host differs from AppBaseUrl.current sends the configured host,
  # not the request host, as HTTP_HOST in the internal Rack request."
  it "sends the configured host, not a hostile server_context host, from a read tool" do
    MCP::Miru::Tools::WorkspaceWhoamiTool.call(
      server_context: { authorization: "Bearer token", host: "attacker.test" }
    )

    expect(sent_requests.size).to eq(1)
    expect(sent_requests.first["HTTP_HOST"]).to eq("configured-host.test")
  end
end

RSpec.describe "MCP tool proxied Host" do
  let(:sent_requests) { [] }

  around do |example|
    original_app_base_url = ENV["APP_BASE_URL"]
    original_default_base_url = Rails.configuration.x.default_base_url
    ENV.delete("APP_BASE_URL")
    Rails.configuration.x.default_base_url = "https://configured-host.test"
    Rails.cache.clear
    example.run
  ensure
    original_app_base_url.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original_app_base_url
    Rails.configuration.x.default_base_url = original_default_base_url
    Rails.cache.clear
  end

  before do
    allow_any_instance_of(Rack::MockRequest).to receive(:request) do |_mock, _verb, _path, options|
      sent_requests << options
      Rack::MockResponse.new(200, { "content-type" => "application/json" }, "{}")
    end
  end

  # Removing the Host override must not change which credential the internal request carries:
  # a bare token is still prefixed and a prefixed one is sent as is.
  it "keeps forwarding the caller's own bearer token when a host is in server_context" do
    MCP::Miru::Tools::WorkspaceWhoamiTool.call(server_context: { authorization: "Bearer token-a", host: "attacker.test" })
    MCP::Miru::Tools::WorkspaceWhoamiTool.call(server_context: { authorization: "token-b", host: "attacker.test" })

    expect(sent_requests.pluck("HTTP_AUTHORIZATION")).to eq(["Bearer token-a", "Bearer token-b"])
    expect(sent_requests.pluck("HTTP_HOST")).to eq(["configured-host.test", "configured-host.test"])
  end
end

RSpec.describe "MCP tool proxied Host" do
  let(:sent_requests) { [] }

  around do |example|
    original_app_base_url = ENV["APP_BASE_URL"]
    original_default_base_url = Rails.configuration.x.default_base_url
    ENV.delete("APP_BASE_URL")
    Rails.configuration.x.default_base_url = "https://configured-host.test"
    Rails.cache.clear
    example.run
  ensure
    original_app_base_url.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original_app_base_url
    Rails.configuration.x.default_base_url = original_default_base_url
    Rails.cache.clear
  end

  before do
    allow_any_instance_of(Rack::MockRequest).to receive(:request) do |_mock, _verb, _path, options|
      sent_requests << options
      Rack::MockResponse.new(201, { "content-type" => "application/json" }, "{}")
    end
  end

  # "A BaseTool invocation whose server_context host differs from AppBaseUrl.current sends the configured host,
  # not the request host, as HTTP_HOST in the internal Rack request."
  it "sends the configured host, not a hostile server_context host, from a write tool" do
    MCP::Miru::Tools::TimeCreateTool.call(
      project_id: 1,
      duration_minutes: 30,
      work_date: "2026-04-22",
      note: "Host check",
      idempotency_key: "base-tool-host-write",
      server_context: { authorization: "Bearer token", host: "attacker.test" }
    )

    expect(sent_requests.size).to eq(1)
    expect(sent_requests.first["HTTP_HOST"]).to eq("configured-host.test")
    expect(sent_requests.first["HTTP_AUTHORIZATION"]).to eq("Bearer token")
  end
end
