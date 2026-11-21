# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Cli::TimesheetEntries#update source metadata", type: :request do
  let(:company) { create(:company, plan_tier: "free") }
  let(:user) { create(:user, current_workspace_id: company.id) }
  let(:client) { create(:client, company:) }
  let(:project) { create(:project, billable: true, client:) }
  let(:cli_token) { CliSession.issue_for(user:, company:).last }
  let(:stored_metadata) { { "tool" => "codex", "skill" => "existing" } }

  before do
    create(:employment, company:, user:)
    user.add_role :employee, company
    create(:project_member, project:, user:)
  end

  def patch_entry(entry_id, **entry_params)
    send_request :patch, api_v1_cli_timesheet_entry_path(entry_id), params: {
      timesheet_entry: { project_id: project.id, duration_minutes: 45, work_date: Date.current.iso8601, **entry_params }
    }, headers: cli_auth_headers(cli_token)
  end

  # Permitted metadata must reach the owner as plain data without bypassing
  # the model's key allow-list: a client-supplied pii key is never stored.
  it "keeps allowed metadata keys and drops a pii key on a CLI update in the owner store", committed_data: true do
    entry_id = arrange_owned_entries(
      [{ company:, user:, project:, work_date: Date.current - 1.day, duration: 30 }],
      state: TimekeepingOwnerState.current
    ).first
    expect_owner_state!

    patch_entry(entry_id, source_metadata: { tool: "claude-code", skill: "gstack-review", pii: "drop-me" })

    expect(response).to have_http_status(:ok)
    expect(json_response.dig("entry", "source_label")).to eq("Claude Code via Automation")
    stored = owned_entry(entry_id, state: TimekeepingOwnerState.current)
    expect(stored.fetch("source")).to eq("automation")
    expect(stored.fetch("source_metadata")).to include("tool" => "claude-code", "skill" => "gstack-review")
    expect(stored.fetch("source_metadata")).not_to have_key("pii")
  end

  # Strong parameters filter out a metadata value that is not a Hash, so the
  # update treats it as omitted instead of overwriting the stored metadata.
  it "keeps stored metadata when a CLI update sends malformed source_metadata", committed_data: true do
    entry_id = arrange_owned_entries(
      [{ company:, user:, project:, work_date: Date.current - 1.day, duration: 30, source_metadata: stored_metadata }],
      state: TimekeepingOwnerState.current
    ).first
    expect_owner_state!

    patch_entry(entry_id, source_metadata: "not-a-hash")

    expect(response).to have_http_status(:ok)
    expect(owned_entry(entry_id, state: TimekeepingOwnerState.current).fetch("source_metadata")).to eq(stored_metadata)
  end

  it "refuses a CLI metadata update to another user's owner-held entry and leaves it unchanged",
     committed_data: true do
    other_user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user: other_user)
    other_entry_id = arrange_owned_entries(
      [{
        company:, user: other_user, project:, work_date: Date.current - 1.day, duration: 30,
        source_metadata: stored_metadata
      }],
      state: TimekeepingOwnerState.current
    ).first
    expect_owner_state!

    patch_entry(other_entry_id, duration_minutes: 15, source_metadata: { tool: "claude-code", skill: "gstack-review" })

    expect(response).to have_http_status(:not_found)
    stored = owned_entry(other_entry_id, state: TimekeepingOwnerState.current)
    expect(stored.fetch("user_id")).to eq(other_user.id)
    expect(Float(stored.fetch("duration"))).to eq(30.0)
    expect(stored.fetch("source_metadata")).to eq(stored_metadata)
  end
end
