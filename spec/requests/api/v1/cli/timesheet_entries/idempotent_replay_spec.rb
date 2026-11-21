# frozen_string_literal: true

require "rails_helper"

# The legacy store owns the entries here, so these retries are answered from
# the legacy receipts the CLI writes under its own actor kind and :actor scope.
RSpec.describe "Api::V1::Cli::TimesheetEntries legacy replay by Idempotency-Key", type: :request do
  let(:company) { create(:company, plan_tier: "free") }
  let(:user) { create(:user, current_workspace_id: company.id) }
  let(:project) { create(:project, billable: true, client: create(:client, company:)) }
  let(:cli_token) { CliSession.issue_for(user:, company:).last }
  let(:audit_count) { ->(entry) { Audited::Audit.where(auditable_type: "TimesheetEntry", auditable_id: entry.id).count } }

  before do
    create(:employment, company:, user:)
    user.add_role :employee, company
    create(:project_member, project:, user:)
  end

  def cli_replay_update_params(note)
    { timesheet_entry: { project_id: project.id, duration_minutes: 45, work_date: Date.current.iso8601, note:,
                         bill_status: "unbilled" } }
  end

  it "replays a committed CLI update retried with the same key after its project was archived" do
    entry = create(:timesheet_entry, user:, project:, work_date: Date.current, duration: 30)
    headers = cli_auth_headers(cli_token).merge("Idempotency-Key" => "cli-update-archived-project")

    send_request :patch, api_v1_cli_timesheet_entry_path(entry), params: cli_replay_update_params("CLI edit"), headers: headers
    expect(response).to have_http_status(:ok)
    first_answer = json_response.deep_dup
    entry_after_first = entry.reload.attributes
    audits_after_first = audit_count.call(entry)

    project.discard

    send_request :patch, api_v1_cli_timesheet_entry_path(entry), params: cli_replay_update_params("CLI edit"), headers: headers

    expect(response).to have_http_status(:ok)
    expect(json_response).to eq(first_answer)
    expect(entry.reload.attributes).to eq(entry_after_first)
    expect(audit_count.call(entry)).to eq(audits_after_first)
  end

  it "refuses a CLI update that reuses a committed update's key with a different body and writes nothing" do
    entry = create(:timesheet_entry, user:, project:, work_date: Date.current, duration: 30)
    headers = cli_auth_headers(cli_token).merge("Idempotency-Key" => "cli-update-reused-key")

    send_request :patch, api_v1_cli_timesheet_entry_path(entry), params: cli_replay_update_params("First"), headers: headers
    expect(response).to have_http_status(:ok)
    audits_after_first = audit_count.call(entry)

    send_request :patch, api_v1_cli_timesheet_entry_path(entry), params: cli_replay_update_params("Second"), headers: headers

    expect(response).to have_http_status(:unprocessable_content)
    expect(json_response["reason"]).to eq("idempotency_key_reused")
    expect(entry.reload.note).to eq("First")
    expect(audit_count.call(entry)).to eq(audits_after_first)
  end

  it "replays a committed CLI delete retried with the same key after the edit window closed" do
    last_editable_day = company.timesheet_edit_days.days.ago.to_date
    entry = create(:timesheet_entry, user:, project:, work_date: last_editable_day)
    headers = cli_auth_headers(cli_token).merge("Idempotency-Key" => "cli-delete-past-deadline")
    # The first delete runs at midday, so just past the next midnight is always inside the 24-hour receipt.
    midday = Time.current.beginning_of_day + 12.hours

    travel_to(midday) do
      send_request :delete, api_v1_cli_timesheet_entry_path(entry), headers: headers
    end
    expect(response).to have_http_status(:ok)
    discarded_at = TimesheetEntry.find(entry.id).discarded_at
    audits_after_first = audit_count.call(entry)

    travel_to(midday.tomorrow.beginning_of_day + 1.minute) do
      send_request :delete, api_v1_cli_timesheet_entry_path(entry), headers: headers
    end

    expect(response).to have_http_status(:ok)
    expect(TimesheetEntry.find(entry.id).discarded_at).to eq(discarded_at)
    expect(audit_count.call(entry)).to eq(audits_after_first)
  end
end
