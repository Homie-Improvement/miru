# frozen_string_literal: true

require "rails_helper"

# The live Timekeeping app reads company and project rows on its own database
# connections, so in the timekeeping state the rows must be committed.
RSpec.describe "Api::V1::TimesheetEntry::BulkActionController#destroy", type: :request, committed_data: true do
  let(:company) { create(:company) }
  let(:user) { create(:user, current_workspace_id: company.id) }
  let(:client) { create(:client, company:) }
  let(:project) { create(:project, client:) }
  let(:entry_row) do
    { company:, user:, project:, work_date: Date.current, duration: 480, bill_status: "non_billable" }
  end
  let(:entry_rows) { [entry_row, entry_row, entry_row] }

  describe "#destroy" do
    before do
      create(:employment, company:, user:)
      user.add_role :admin, company
      sign_in user
    end

    it "deletes the timesheet entries for the selected ids" do
      entry1_id, entry2_id, entry3_id = arrange_owned_entries(entry_rows)
      expect_owner_state!

      send_request :delete, api_v1_bulk_action_path,
        params: { source: { ids: [entry1_id, entry2_id] } },
        headers: auth_headers(user)

      expect(response).to be_successful
      expect(json_response["notice"]).to match("Timesheet deleted")
      expect([entry1_id, entry2_id].count { |id| owned_entry(id).fetch("discarded_at").nil? }).to eq(0)
      expect([entry3_id].count { |id| owned_entry(id).fetch("discarded_at").nil? }).to eq(1)
    end

    it "rejects client users" do
      client_user = create(:user, current_workspace_id: company.id)
      create(:client_member, company:, user: client_user, client:)
      client_user.add_role :client, company
      entry1_id, = arrange_owned_entries(entry_rows)

      sign_in client_user
      expect_owner_state!
      send_request :delete, api_v1_bulk_action_path,
        params: { source: { ids: [entry1_id] } },
        headers: auth_headers(client_user)

      expect(response).to have_http_status(:forbidden)
    end

    it "rejects employees when selected entries are outside the edit window" do
      employee = create(:user, current_workspace_id: company.id)
      create(:employment, company:, user: employee)
      employee.add_role :employee, company
      employee.remove_role :owner, company
      employee.remove_role :admin, company
      *, old_entry_id = arrange_owned_entries(
        entry_rows + [entry_row.merge(user: employee, work_date: 31.days.ago.to_date)]
      )

      sign_out user
      expect_owner_state!
      send_request :delete, api_v1_bulk_action_path,
        params: { source: { ids: [old_entry_id] } },
        headers: auth_headers(employee)

      expect(response).to have_http_status(:forbidden)
    end

    it "does not destroy entries from another workspace" do
      other_company = create(:company)
      other_client = create(:client, company: other_company)
      other_project = create(:project, client: other_client)
      other_user = create(:user, current_workspace_id: other_company.id)
      create(:employment, company: other_company, user: other_user)
      *, other_entry_id = arrange_owned_entries(
        entry_rows + [entry_row.merge(company: other_company, user: other_user, project: other_project)]
      )

      expect_owner_state!
      send_request :delete, api_v1_bulk_action_path,
        params: { source: { ids: [other_entry_id] } },
        headers: auth_headers(user)

      expect(response).to have_http_status(:unprocessable_content)
      expect(owned_entry(other_entry_id).fetch("discarded_at")).to be_nil
    end

    it "only destroys current workspace entries when mixed ids are submitted" do
      other_company = create(:company)
      other_client = create(:client, company: other_company)
      other_project = create(:project, client: other_client)
      other_user = create(:user, current_workspace_id: other_company.id)
      create(:employment, company: other_company, user: other_user)
      *, other_entry_id, current_entry_id = arrange_owned_entries(
        entry_rows + [entry_row.merge(company: other_company, user: other_user, project: other_project), entry_row]
      )

      expect_owner_state!
      send_request :delete, api_v1_bulk_action_path,
        params: { source: { ids: [current_entry_id, other_entry_id] } },
        headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(owned_entry(current_entry_id).fetch("discarded_at")).not_to be_nil
      expect(owned_entry(other_entry_id).fetch("discarded_at")).to be_nil
    end

    it "rejects employees when selected entries are billed" do
      employee = create(:user, current_workspace_id: company.id)
      create(:employment, company:, user: employee)
      employee.add_role :employee, company
      *, billed_entry_id = arrange_owned_entries(
        entry_rows + [entry_row.merge(user: employee, bill_status: "billed")]
      )

      sign_out user
      sign_in employee
      expect_owner_state!
      send_request :delete, api_v1_bulk_action_path,
        params: { source: { ids: [billed_entry_id] } },
        headers: auth_headers(employee)

      expect(response).to have_http_status(:forbidden)
      expect(owned_entry(billed_entry_id).fetch("discarded_at")).to be_nil
    end

    it "rejects admins when selected entries are billed" do
      *, billed_entry_id = arrange_owned_entries(entry_rows + [entry_row.merge(bill_status: "billed")])

      expect_owner_state!
      send_request :delete, api_v1_bulk_action_path,
        params: { source: { ids: [billed_entry_id] } },
        headers: auth_headers(user)

      expect(response).to have_http_status(:forbidden)
      expect(owned_entry(billed_entry_id).fetch("discarded_at")).to be_nil
    end
  end
end
