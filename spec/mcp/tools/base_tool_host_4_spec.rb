# frozen_string_literal: true

require "rails_helper"

RSpec.describe "MCP tool proxied Host" do
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
      sent_requests << options
      Rack::MockResponse.new(200, { "content-type" => "application/json" }, "{}")
    end
  end

  # "A BaseTool invocation whose server_context host differs from AppBaseUrl.current sends the configured host, not the request host, as HTTP_HOST in the internal Rack request."
  it "sends the configured host, not the server_context host, as HTTP_HOST from a read tool call" do
    MCP::Miru::Tools::WorkspaceWhoamiTool.call(
      server_context: { authorization: "Bearer token", host: "www.example.com" }
    )

    expect(sent_requests.pluck("HTTP_HOST")).to eq(["configured-host.test"])
  end
end

RSpec.describe "MCP tool proxied Host and Authorization" do
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
      sent_requests << options
      Rack::MockResponse.new(200, { "content-type" => "application/json" }, "{}")
    end
  end

  it "keeps the forwarded bearer token while ignoring the server_context host" do
    MCP::Miru::Tools::WorkspaceWhoamiTool.call(server_context: { authorization: "Bearer token", host: "www.example.com" })
    MCP::Miru::Tools::WorkspaceWhoamiTool.call(server_context: { authorization: "token", host: "www.example.com" })

    expect(sent_requests.pluck("HTTP_AUTHORIZATION")).to eq(["Bearer token", "Bearer token"])
    expect(sent_requests.pluck("HTTP_HOST")).to eq(["configured-host.test", "configured-host.test"])
  end
end

RSpec.describe "MCP write tool proxied Host" do
  let(:sent_hosts) { [] }
  let(:company) { create(:company, plan_tier: "paid") }
  let(:user) { create(:user, current_workspace_id: company.id) }
  let(:project) { create(:project, billable: true, client: create(:client, company:)) }
  let(:cli_token) { CliSession.issue_for(user:, company:).last }

  around do |example|
    original_app_base_url = ENV["APP_BASE_URL"]
    original_default_base_url = Rails.configuration.x.default_base_url
    ENV.delete("APP_BASE_URL")
    Rails.configuration.x.default_base_url = "https://configured-host.test"
    Rails.cache.clear
    example.run
  ensure
    Rails.cache.clear
    original_app_base_url.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original_app_base_url
    Rails.configuration.x.default_base_url = original_default_base_url
  end

  before do
    create(:employment, company:, user:)
    create(:project_member, project:, user:)
    user.add_role :employee, company
    allow_any_instance_of(Rack::MockRequest).to receive(:request) do |_mock, _verb, _path, options|
      sent_hosts << options["HTTP_HOST"]
      Rack::MockResponse.new(201, { "content-type" => "application/json" }, "{}")
    end
  end

  # "A BaseTool invocation whose server_context host differs from AppBaseUrl.current sends the configured host, not the request host, as HTTP_HOST in the internal Rack request."
  it "sends the configured host, not the server_context host, as HTTP_HOST from a write tool call" do
    MCP::Miru::Tools::TimeCreateTool.call(
      project_id: project.id, duration_minutes: 20, work_date: Date.current.iso8601,
      note: "Host check", idempotency_key: "mcp-configured-host-create",
      server_context: { authorization: "Bearer #{cli_token}", host: "www.example.com" }
    )

    expect(sent_hosts).to eq(["configured-host.test"])
  end
end
