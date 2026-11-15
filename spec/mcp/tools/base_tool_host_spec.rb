# frozen_string_literal: true

require "rails_helper"

# "A BaseTool invocation whose server_context host differs from AppBaseUrl.current sends the configured host,
# not the request host, as HTTP_HOST in the internal Rack request."
RSpec.describe "MCP tool proxied Host" do
  let(:sent_requests) { [] }
  let(:proxied_response_status) { 201 }

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
      Rack::MockResponse.new(proxied_response_status, { "content-type" => "application/json" }, "{}")
    end
  end

  def create_time_entry(server_context:, idempotency_key:)
    MCP::Miru::Tools::TimeCreateTool.call(
      project_id: 1,
      duration_minutes: 30,
      work_date: "2026-04-22",
      note: "Host check",
      idempotency_key:,
      server_context:
    )
  end

  it "sends the configured host, not a hostile server_context host, from a read tool" do
    MCP::Miru::Tools::WorkspaceWhoamiTool.call(
      server_context: { authorization: "Bearer token", host: "attacker.test" }
    )

    expect(sent_requests.size).to eq(1)
    expect(sent_requests.first["HTTP_HOST"]).to eq("configured-host.test")
  end

  # String keys are symbolized by BaseTool, so this shape reached the old Host override too.
  it "sends the configured host when the server context carries a hostile host with a port under string keys" do
    MCP::Miru::Tools::WorkspaceWhoamiTool.call(
      server_context: { "authorization" => "Bearer token", "host" => "attacker.test:6666" }
    )

    expect(sent_requests.pluck("HTTP_HOST")).to eq(["configured-host.test"])
  end

  # Removing the Host override must not change which credential the internal request carries:
  # a bare token is still prefixed and a prefixed one is sent as is.
  it "keeps forwarding the caller's own bearer token when a host is in server_context" do
    MCP::Miru::Tools::WorkspaceWhoamiTool.call(server_context: { authorization: "Bearer token-a", host: "attacker.test" })
    MCP::Miru::Tools::WorkspaceWhoamiTool.call(server_context: { authorization: "token-b", host: "attacker.test" })

    expect(sent_requests.pluck("HTTP_AUTHORIZATION")).to eq(["Bearer token-a", "Bearer token-b"])
    expect(sent_requests.pluck("HTTP_HOST")).to eq(["configured-host.test", "configured-host.test"])
  end

  it "sends the configured host, not a hostile server_context host, from a write tool" do
    create_time_entry(
      server_context: { authorization: "Bearer token", host: "attacker.test" },
      idempotency_key: "base-tool-host-write"
    )

    expect(sent_requests.size).to eq(1)
    expect(sent_requests.first["HTTP_HOST"]).to eq("configured-host.test")
    expect(sent_requests.first["HTTP_AUTHORIZATION"]).to eq("Bearer token")
  end

  # A retry may arrive from a different host; whichever delivery reaches the internal API must carry the configured host.
  # The first delivery fails, so the idempotency store caches nothing and the retry reaches the proxy too.
  context "when a failed write is retried from a different request host" do
    let(:proxied_response_status) { 503 }

    it "sends the configured host on a write delivered twice with different request hosts under one idempotency key" do
      ["first-request.test", "second-request.test"].each do |request_host|
        create_time_entry(
          server_context: { authorization: "Bearer token", host: request_host },
          idempotency_key: "mcp-host-retry"
        )
      end

      expect(sent_requests.size).to eq(2)
      expect(sent_requests.pluck("HTTP_HOST")).to eq(["configured-host.test", "configured-host.test"])
    end
  end
end
