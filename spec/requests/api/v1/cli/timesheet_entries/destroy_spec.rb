# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Cli::TimesheetEntries#destroy", type: :request do
  let(:company) { create(:company, plan_tier: "free") }
  let(:user) { create(:user, current_workspace_id: company.id) }
  let(:client) { create(:client, company:) }
  let(:project) { create(:project, billable: true, client:) }
  let(:cli_token) { CliSession.issue_for(user:, company:).last }

  before do
    create(:employment, company:, user:)
    user.add_role :employee, company
    create(:project_member, project:, user:)
  end

  it "deletes one of the authenticated user's timesheet entries", committed_data: true do
    entry_id, = arrange_owned_entries(
      [{ company:, user:, project:, work_date: Date.current, duration: 480, note: "Did that", bill_status: "non_billable" }],
      state: TimekeepingOwnerState.current
    )
    expect_owner_state!

    send_request :delete, api_v1_cli_timesheet_entry_path(entry_id), headers: cli_auth_headers(cli_token)

    expect(response).to have_http_status(:ok)
    expect(json_response["notice"]).to eq(I18n.t("timesheet_entry.destroy.message"))
    expect(owned_entry(entry_id, state: TimekeepingOwnerState.current).fetch("discarded_at")).not_to be_nil
  end

  it "does not allow deleting another user's timesheet entry", committed_data: true do
    other_user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user: other_user)
    other_entry_id, = arrange_owned_entries(
      [{ company:, user: other_user, project:, work_date: Date.current, duration: 480, note: "Did that", bill_status: "non_billable" }],
      state: TimekeepingOwnerState.current
    )
    expect_owner_state!

    send_request :delete, api_v1_cli_timesheet_entry_path(other_entry_id), headers: cli_auth_headers(cli_token)

    expect(response).to have_http_status(:not_found)
  end
end
