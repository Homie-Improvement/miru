# frozen_string_literal: true

require "rails_helper"

RSpec.describe "MCP BaseTool hostile request host" do
  let(:hosts_sent_for_hostile_context) { [] }

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
      hosts_sent_for_hostile_context << options["HTTP_HOST"]
      Rack::MockResponse.new(200, { "content-type" => "application/json" }, "{}")
    end
  end

  # "A BaseTool invocation whose server_context host differs from AppBaseUrl.current sends the configured host, not the request host, as HTTP_HOST in the internal Rack request."
  # String keys are symbolized by BaseTool, so this shape reached the old Host override too.
  it "sends the configured host when the server context carries a hostile host with a port under string keys" do
    MCP::Miru::Tools::WorkspaceWhoamiTool.call(
      server_context: { "authorization" => "Bearer token", "host" => "attacker.test:6666" }
    )

    expect(hosts_sent_for_hostile_context).to eq(["configured-host.test"])
  end
end

RSpec.describe "MCP BaseTool request host on repeated writes" do
  let(:company) { create(:company, plan_tier: "paid") }
  let(:user) { create(:user, current_workspace_id: company.id) }
  let(:project) { create(:project, billable: true, client: create(:client, company:)) }
  let(:cli_token) { CliSession.issue_for(user:, company:).last }
  let(:hosts_sent_for_repeated_write) { [] }

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
      hosts_sent_for_repeated_write << options["HTTP_HOST"]
      Rack::MockResponse.new(201, { "content-type" => "application/json" }, "{}")
    end
  end

  # "A BaseTool invocation whose server_context host differs from AppBaseUrl.current sends the configured host, not the request host, as HTTP_HOST in the internal Rack request."
  # A retry may arrive from a different host; whichever delivery reaches the internal API must carry the configured host.
  it "sends the configured host on a write delivered twice with different request hosts under one idempotency key" do
    ["first-request.test", "second-request.test"].each do |request_host|
      MCP::Miru::Tools::TimeCreateTool.call(
        project_id: project.id, duration_minutes: 20, work_date: Date.current.iso8601,
        note: "Retried write", idempotency_key: "mcp-host-retry",
        server_context: { authorization: "Bearer #{cli_token}", host: request_host }
      )
    end

    expect(hosts_sent_for_repeated_write).not_to be_empty
    expect(hosts_sent_for_repeated_write.uniq).to eq(["configured-host.test"])
  end
end
