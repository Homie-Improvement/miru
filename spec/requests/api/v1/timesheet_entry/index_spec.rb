# frozen_string_literal: true

require "rails_helper"

# The live Timekeeping app reads company and project rows on its own database
# connections, so in the timekeeping state the rows must be committed.
RSpec.describe "Api::V1::TimesheetEntry#index", type: :request, committed_data: true do
  let(:company) { create(:company) }
  let(:user) { create(:user, current_workspace_id: company.id) }
  let(:other_user) { create(:user, current_workspace_id: company.id) }
  let(:client) { create(:client, company:) }
  let(:project) { create(:project, client:) }
  let(:leave) { create(:leave, company:, year: Date.current.year) }
  let!(:leave_type) { create(:leave_type, leave:, name: "PTO") }
  let(:old_entry_work_date) { Date.current - 180.days }
  let(:old_entry_row) do
    { company:, user:, project:, work_date: old_entry_work_date, duration: 480, note: "Old entry still viewable",
      bill_status: "non_billable" }
  end
  let!(:timeoff_entry) do
    create(
      :timeoff_entry,
      user:,
      leave_type:,
      leave_date: Date.current - 180.days,
      duration: 480,
      note: "PTO applied"
    )
  end

  before do
    create(:employment, company:, user:)
    create(:employment, company:, user: other_user)
    user.add_role :admin, company
    sign_in user
  end

  it "returns older entries without raising when proof_url is blank" do
    old_entry_id, = arrange_owned_entries([old_entry_row])
    expect_owner_state!

    send_request :get, api_v1_timesheet_entry_index_path, params: {
      from: (Date.current - 365.days).iso8601,
      to: Date.current.iso8601
    }, headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    entry = json_response.dig("entries", old_entry_work_date.iso8601).first
    expect(entry["id"]).to eq(old_entry_id)
    expect(entry["proof_url"]).to be_nil
    expect(entry["note"]).to eq("Old entry still viewable")
  end

  it "includes timeoff entries and leave metadata in the response" do
    arrange_owned_entries([old_entry_row])
    expect_owner_state!

    send_request :get, api_v1_timesheet_entry_index_path, params: {
      from: (Date.current - 365.days).iso8601,
      to: Date.current.iso8601,
      year: Date.current.year
    }, headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    leave_entry = json_response.fetch("entries").values.flatten.find do |entry|
      entry["type"] == "leave" && entry["leave_type_id"] == leave_type.id
    end

    expect(leave_entry["type"]).to eq("leave")
    expect(leave_entry["id"]).to eq(timeoff_entry.id)
    expect(leave_entry["leave_type_id"]).to eq(leave_type.id)
    expect(leave_entry["note"]).to eq("PTO applied")
    expect(json_response["leave_types"].pluck("id")).to include(leave_type.id)
  end

  it "returns leave entries for day-first date params used by week navigation" do
    company.update!(date_format: "MM-DD-YYYY")
    target_date = Date.current.beginning_of_week - 7.days
    weekly_timeoff_entry = create(
      :timeoff_entry,
      user:,
      leave_type:,
      leave_date: target_date,
      duration: 480,
      note: "Week navigation PTO"
    )
    arrange_owned_entries([old_entry_row])
    expect_owner_state!

    send_request :get, api_v1_timesheet_entry_index_path, params: {
      from: target_date.beginning_of_week.strftime("%d-%m-%Y"),
      to: target_date.end_of_week.strftime("%d-%m-%Y"),
      year: target_date.year
    }, headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    leave_entry = json_response.fetch("entries").values.flatten.find do |entry|
      entry["id"] == weekly_timeoff_entry.id
    end

    expect(leave_entry["type"]).to eq("leave")
    expect(leave_entry["leave_type_id"]).to eq(leave_type.id)
  end

  it "prefers the shortest valid ambiguous date range inside MM-DD workspaces" do
    company.update!(date_format: "MM-DD-YYYY")
    target_date = Date.new(2026, 4, 6)
    ambiguous_timeoff_entry = create(
      :timeoff_entry,
      user:,
      leave_type:,
      leave_date: target_date,
      duration: 480,
      note: "Ambiguous range PTO"
    )
    arrange_owned_entries([old_entry_row])
    expect_owner_state!

    send_request :get, api_v1_timesheet_entry_index_path, params: {
      from: "06-04-2026",
      to: "12-04-2026",
      year: 2026
    }, headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    leave_entry = json_response.fetch("entries").values.flatten.find do |entry|
      entry["id"] == ambiguous_timeoff_entry.id
    end

    expect(leave_entry["type"]).to eq("leave")
    expect(leave_entry["leave_type_id"]).to eq(leave_type.id)
  end

  it "ignores another user's user_id for employees" do
    employee_user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user: employee_user)
    employee_user.add_role :employee, company
    _old_entry_id, own_entry_id, other_entry_id = arrange_owned_entries([
      old_entry_row,
      { company:, user: employee_user, project:, work_date: old_entry_work_date, duration: 480,
        note: "Own employee entry", bill_status: "non_billable" },
      { company:, user: other_user, project:, work_date: old_entry_work_date, duration: 480,
        note: "Other user entry", bill_status: "non_billable" }
    ])

    sign_out user
    sign_in employee_user
    expect_owner_state!

    send_request :get, api_v1_timesheet_entry_index_path, params: {
      from: (Date.current - 365.days).iso8601,
      to: Date.current.iso8601,
      user_id: other_user.id
    }, headers: auth_headers(employee_user)

    expect(response).to have_http_status(:ok)
    flattened_entries = json_response.fetch("entries").values.flatten
    expect(flattened_entries.pluck("id")).not_to include(other_entry_id)
    expect(flattened_entries.pluck("id")).to include(own_entry_id)
  end
end
