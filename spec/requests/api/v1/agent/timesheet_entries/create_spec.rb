# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Agent::TimesheetEntries#create", type: :request do
  let(:company) { create(:company, plan_tier: "free") }
  let(:user) { create(:user, current_workspace_id: company.id) }
  let(:client) { create(:client, company:) }
  let(:project) { create(:project, billable: true, client:) }
  let(:agent) { create(:agent, company:, user:, default_project: project, provider: "codex") }
  let(:issued_key) { AgentKey.issue_for(agent:, name: "Primary Key", created_by: user) }
  let(:agent_token) { issued_key.last }

  before do
    create(:employment, company:, user:)
    create(:project_member, project:, user:)
    user.add_role :employee, company
  end

  it "creates a reviewable timesheet entry for the authenticated agent", committed_data: true do
    expect_owner_state!

    send_request :post, api_v1_agent_timesheet_entries_path, params: {
      timesheet_entry: {
        duration_minutes: 60,
        work_date: Date.current.iso8601,
        note: "Generated invoice follow-up draft",
        source_metadata: {
          tool: "claude-code",
          skill: "gstack-review",
          pii: "drop-me"
        },
        proof_url: "https://example.test/runs/123",
        proof_metadata: {
          transcript_url: "https://example.test/transcripts/123",
          repo: "saeloun/miru-web"
        },
        external_run_id: "run_123",
        external_session_id: "session_123"
      }
    }, headers: { "Authorization" => "Bearer #{agent_token}" }

    expect(response).to have_http_status(:ok)
    entry = owned_entry(json_response.dig("entry", "id"), state: TimekeepingOwnerState.current)

    expect(entry.fetch("user_id")).to eq(user.id)
    expect(entry.fetch("agent_id")).to eq(agent.id)
    expect(entry.fetch("project_id")).to eq(project.id)
    expect(entry.fetch("bill_status")).to eq("unbilled")
    expect(entry.fetch("review_status")).to eq("pending_review")
    expect(entry.fetch("source")).to eq("automation")
    expect(entry.fetch("source_metadata")).to eq(
      "tool" => "claude-code",
      "skill" => "gstack-review"
    )
    expect(entry.fetch("proof_metadata")).to eq(
      "transcript_url" => "https://example.test/transcripts/123",
      "repo" => "saeloun/miru-web"
    )
    expect(json_response.dig("entry", "agent_name")).to eq(agent.name)
    expect(json_response.dig("entry", "review_status")).to eq("pending_review")
  end

  it "rejects revoked agent keys" do
    issued_key.first.revoke!
    expect_owner_state!

    send_request :post, api_v1_agent_timesheet_entries_path, params: {
      timesheet_entry: {
        project_id: project.id,
        duration_minutes: 30,
        work_date: Date.current.iso8601,
        bill_status: "billed"
      }
    }, headers: { "Authorization" => "Bearer #{agent_token}" }

    expect(response).to have_http_status(:unauthorized)
  end

  it "rejects a project outside the backing user's membership scope", committed_data: true do
    other_project = create(:project, client:)
    expect_owner_state!

    send_request :post, api_v1_agent_timesheet_entries_path, params: {
      timesheet_entry: {
        project_id: other_project.id,
        duration_minutes: 30,
        work_date: Date.current.iso8601
      }
    }, headers: { "Authorization" => "Bearer #{agent_token}" }

    expect(response).to have_http_status(:not_found)
    owned_for_other_project = owned_entries(state: TimekeepingOwnerState.current).select do |entry|
      entry.fetch("project_id") == other_project.id && entry.fetch("user_id") == user.id
    end
    expect(owned_for_other_project).to be_empty
  end

  it "returns unauthorized for missing or malformed tokens" do
    expect_owner_state!

    send_request :post, api_v1_agent_timesheet_entries_path, params: {
      timesheet_entry: {
        project_id: project.id,
        duration_minutes: 30,
        work_date: Date.current.iso8601
      }
    }
    expect(response).to have_http_status(:unauthorized)

    send_request :post, api_v1_agent_timesheet_entries_path, params: {
      timesheet_entry: {
        project_id: project.id,
        duration_minutes: 30,
        work_date: Date.current.iso8601
      }
    }, headers: { "Authorization" => "Bearer invalid-token" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns not found when no explicit or default project is available" do
    agent.update!(default_project: nil)
    expect_owner_state!

    send_request :post, api_v1_agent_timesheet_entries_path, params: {
      timesheet_entry: {
        duration_minutes: 30,
        work_date: Date.current.iso8601
      }
    }, headers: { "Authorization" => "Bearer #{agent_token}" }

    expect(response).to have_http_status(:not_found)
  end

  it "returns unauthorized when the backing user is inactive" do
    user.discard
    expect_owner_state!

    send_request :post, api_v1_agent_timesheet_entries_path, params: {
      timesheet_entry: {
        project_id: project.id,
        duration_minutes: 30,
        work_date: Date.current.iso8601
      }
    }, headers: { "Authorization" => "Bearer #{agent_token}" }

    expect(response).to have_http_status(:unauthorized)
  end
end
