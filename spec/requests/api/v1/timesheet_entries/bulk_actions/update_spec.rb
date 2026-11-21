# frozen_string_literal: true

require "rails_helper"

# The live Timekeeping app reads company and project rows on its own database
# connections, so in the timekeeping state the rows must be committed.
RSpec.describe "Api::V1::TimesheetEntry::BulkActionController#update", type: :request, committed_data: true do
  let(:company) { create(:company) }
  let(:user) { create(:user, current_workspace_id: company.id) }
  let(:client) { create(:client, company:) }
  let(:project1) { create(:project, client:) }
  let(:project2) { create(:project, client:) }
  let(:entry_row) do
    { company:, user:, project: project1, work_date: Date.current, duration: 480, bill_status: "non_billable" }
  end
  let(:entry_rows) { [entry_row, entry_row, entry_row] }

  describe "#update" do
    before do
      create(:employment, company:, user:)
      user.add_role :admin, company
      sign_in user
    end

    it "updates the timesheet entry projects for passed ids" do
      entry1_id, entry2_id, entry3_id = arrange_owned_entries(entry_rows)
      expect_owner_state!

      send_request :patch, api_v1_bulk_action_path,
        params: { ids: [entry1_id, entry2_id], project_id: project2.id },
        headers: auth_headers(user)

      expect(response).to be_successful
      expect(json_response["notice"]).to match("Timesheet updated")

      expected_project_id = [entry1_id, entry2_id].map { |id| owned_entry(id).fetch("project_id") }.uniq
      expect(expected_project_id.first).to eq(project2.id)

      expect(owned_entry(entry3_id).fetch("project_id")).to eq(project1.id)
    end

    it "rejects client users" do
      client_user = create(:user, current_workspace_id: company.id)
      create(:client_member, company:, user: client_user, client:)
      client_user.add_role :client, company
      entry1_id, = arrange_owned_entries(entry_rows)

      sign_in client_user
      expect_owner_state!
      send_request :patch, api_v1_bulk_action_path,
        params: { ids: [entry1_id], project_id: project2.id },
        headers: auth_headers(client_user)

      expect(response).to have_http_status(:forbidden)
    end

    it "rejects employees when selected entries are outside the edit window" do
      employee = create(:user, current_workspace_id: company.id)
      create(:employment, company:, user: employee)
      employee.add_role :employee, company
      employee.remove_role :owner, company
      employee.remove_role :admin, company
      create(:project_member, project: project1, user: employee)
      *, old_entry_id = arrange_owned_entries(
        entry_rows + [entry_row.merge(user: employee, work_date: 31.days.ago.to_date)]
      )

      sign_out user
      expect_owner_state!
      send_request :patch, api_v1_bulk_action_path,
        params: { ids: [old_entry_id], project_id: project1.id },
        headers: auth_headers(employee)

      expect(response).to have_http_status(:forbidden)
    end

    it "rejects an empty selection" do
      expect_owner_state!
      send_request :patch, api_v1_bulk_action_path,
        params: { ids: [], project_id: project2.id },
        headers: auth_headers(user)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response["error"]).to eq("Failed to update timesheet entries")
    end

    it "does not update entries from another workspace" do
      other_company = create(:company)
      other_client = create(:client, company: other_company)
      other_project = create(:project, client: other_client)
      other_user = create(:user, current_workspace_id: other_company.id)
      create(:employment, company: other_company, user: other_user)
      *, other_entry_id = arrange_owned_entries(
        entry_rows + [entry_row.merge(company: other_company, user: other_user, project: other_project)]
      )

      expect_owner_state!
      send_request :patch, api_v1_bulk_action_path,
        params: { ids: [other_entry_id], project_id: project2.id },
        headers: auth_headers(user)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response["error"]).to eq("Failed to update timesheet entries")
      expect(owned_entry(other_entry_id).fetch("project_id")).to eq(other_project.id)
    end

    it "does not move entries to projects from another workspace" do
      other_company = create(:company)
      other_client = create(:client, company: other_company)
      other_project = create(:project, client: other_client)
      *, entry3_id = arrange_owned_entries(entry_rows)

      expect_owner_state!
      send_request :patch, api_v1_bulk_action_path,
        params: { ids: [entry3_id], project_id: other_project.id },
        headers: auth_headers(user)

      expect(response).to have_http_status(:not_found)
      expect(owned_entry(entry3_id).fetch("project_id")).to eq(project1.id)
    end

    it "rejects employees when selected entries are billed" do
      employee = create(:user, current_workspace_id: company.id)
      create(:employment, company:, user: employee)
      employee.add_role :employee, company
      create(:project_member, project: project1, user: employee)
      *, billed_entry_id = arrange_owned_entries(
        entry_rows + [entry_row.merge(user: employee, bill_status: "billed")]
      )

      sign_out user
      expect_owner_state!
      send_request :patch, api_v1_bulk_action_path,
        params: { ids: [billed_entry_id], project_id: project1.id },
        headers: auth_headers(employee)

      expect(response).to have_http_status(:forbidden)
    end

    it "rejects admins when selected entries are billed" do
      *, billed_entry_id = arrange_owned_entries(entry_rows + [entry_row.merge(bill_status: "billed")])

      expect_owner_state!
      send_request :patch, api_v1_bulk_action_path,
        params: { ids: [billed_entry_id], project_id: project2.id },
        headers: auth_headers(user)

      expect(response).to have_http_status(:forbidden)
      expect(owned_entry(billed_entry_id).fetch("project_id")).to eq(project1.id)
    end
  end
end
