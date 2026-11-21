# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Cli::TimesheetEntries#update", type: :request do
  let(:company) { create(:company, plan_tier: "free") }
  let(:user) { create(:user, current_workspace_id: company.id) }
  let(:client) { create(:client, company:) }
  let(:project) { create(:project, billable: true, client:) }
  let(:other_project) { create(:project, billable: true, client:) }
  let(:cli_token) { CliSession.issue_for(user:, company:).last }

  before do
    create(:employment, company:, user:)
    user.add_role :employee, company
    create(:project_member, project:, user:)
    create(:project_member, project: other_project, user:)
  end

  it "updates one of the authenticated user's timesheet entries", committed_data: true do
    entry_id, = arrange_owned_entries(
      [{ company:, user:, project:, work_date: Date.current - 1.day, duration: 30, note: "Did that", bill_status: "non_billable" }],
      state: TimekeepingOwnerState.current
    )
    expect_owner_state!

    send_request :patch, api_v1_cli_timesheet_entry_path(entry_id), params: {
      timesheet_entry: {
        project_id: other_project.id,
        duration_minutes: 45,
        work_date: Date.current.iso8601,
        note: "Updated from CLI",
        bill_status: "unbilled"
      }
    }, headers: cli_auth_headers(cli_token)

    expect(response).to have_http_status(:ok)
    expect(json_response.dig("entry", "project_id")).to eq(other_project.id)
    expect(json_response.dig("entry", "duration")).to eq(45.0)
    updated_entry = owned_entry(entry_id, state: TimekeepingOwnerState.current)
    expect(updated_entry.fetch("note")).to eq("Updated from CLI")
    expect(updated_entry.fetch("source")).to eq("cli")
  end

  it "updates AI source metadata on an existing timesheet entry", committed_data: true do
    entry_id, = arrange_owned_entries(
      [{ company:, user:, project:, work_date: Date.current - 1.day, duration: 30, note: "Did that", bill_status: "non_billable" }],
      state: TimekeepingOwnerState.current
    )
    expect_owner_state!

    send_request :patch, api_v1_cli_timesheet_entry_path(entry_id), params: {
      timesheet_entry: {
        project_id: other_project.id,
        duration_minutes: 45,
        work_date: Date.current.iso8601,
        note: "Updated from Codex",
        bill_status: "unbilled",
        source_metadata: {
          tool: "claude-code",
          skill: "gstack-review"
        }
      }
    }, headers: cli_auth_headers(cli_token)

    expect(response).to have_http_status(:ok)
    expect(json_response.dig("entry", "source_label")).to eq("Claude Code via Automation")
    expect(owned_entry(entry_id, state: TimekeepingOwnerState.current).fetch("source_metadata")).to include(
      "tool" => "claude-code",
      "skill" => "gstack-review"
    )
  end

  it "preserves optional fields when they are omitted", committed_data: true do
    entry_id, = arrange_owned_entries(
      [{
        company:, user:, project:, work_date: Date.current - 1.day, duration: 30,
        note: "Keep me", bill_status: "non_billable", source_metadata: { "tool" => "codex", "skill" => "existing" }
      }],
      state: TimekeepingOwnerState.current
    )
    expect_owner_state!

    send_request :patch, api_v1_cli_timesheet_entry_path(entry_id), params: {
      timesheet_entry: {
        project_id: other_project.id,
        duration_minutes: 45,
        work_date: Date.current.iso8601
      }
    }, headers: cli_auth_headers(cli_token)

    expect(response).to have_http_status(:ok)
    kept_entry = owned_entry(entry_id, state: TimekeepingOwnerState.current)
    expect(kept_entry.fetch("note")).to eq("Keep me")
    expect(kept_entry.fetch("bill_status")).to eq("non_billable")
    expect(kept_entry.fetch("source_metadata")).to eq({ "tool" => "codex", "skill" => "existing" })
  end

  it "does not allow updating another user's timesheet entry", committed_data: true do
    other_user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user: other_user)
    other_entry_id, = arrange_owned_entries(
      [{ company:, user: other_user, project:, work_date: Date.current, duration: 480, note: "Did that", bill_status: "non_billable" }],
      state: TimekeepingOwnerState.current
    )
    expect_owner_state!

    send_request :patch, api_v1_cli_timesheet_entry_path(other_entry_id), params: {
      timesheet_entry: {
        project_id: project.id,
        duration_minutes: 15,
        work_date: Date.current.iso8601
      }
    }, headers: cli_auth_headers(cli_token)

    expect(response).to have_http_status(:not_found)
  end
end
