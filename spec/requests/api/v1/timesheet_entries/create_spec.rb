# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::TimesheetEntry#create", type: :request do
  let_it_be(:company) { create(:company) }
  let_it_be(:client) { create(:client, company:) }
  let_it_be(:project) { create(:project, billable: true, client:) }
  let(:user) { create(:user, email: "timesheet-create-#{SecureRandom.hex(6)}@example.com", current_workspace_id: company.id) }
  let(:work_date) { Date.current }
  let(:entry_params) do
    {
      project_id: project.id,
      timesheet_entry: {
        duration: 20,
        work_date: work_date,
        note: "Test Note",
        bill_status: :unbilled
      },
      user_id: user.id
    }
  end

  context "when user is an admin" do
    before do
      create(:employment, company:, user:)
      user.add_role :admin, company
      sign_in user
    end

    it "they should be able to create the record successfully" do
      expect do
        send_request :post, api_v1_timesheet_entry_index_path, params: entry_params, headers: auth_headers(user)
      end.to change(TimesheetEntry, :count).by(1)

      expect(response).to be_successful
    end

    it "returns success json response" do
      send_request :post, api_v1_timesheet_entry_index_path, params: entry_params, headers: auth_headers(user)

      expect(json_response["entry"]["project_id"]).to match(project.id)
      expect(json_response["notice"]).to match("Timesheet created")

      created_entry = TimesheetEntry.find(json_response["entry"]["id"])
      expect(created_entry.user_id).to eq(user.id)
      expect(created_entry.project_id).to eq(project.id)
      expect(created_entry.note).to eq("Test Note")
      expect(created_entry.duration).to eq(20)
      expect(created_entry.bill_status).to eq("unbilled")
    end

    it "does not create entries on projects from another workspace" do
      other_company = create(:company)
      other_client = create(:client, company: other_company)
      other_project = create(:project, client: other_client)

      expect do
        send_request :post, api_v1_timesheet_entry_index_path,
          params: entry_params.merge(project_id: other_project.id),
          headers: auth_headers(user)
      end.not_to change(TimesheetEntry, :count)

      expect(response).to have_http_status(:not_found)
    end

    it "does not create entries for users from another workspace" do
      other_company = create(:company)
      other_user = create(:user, current_workspace_id: other_company.id)
      create(:employment, company: other_company, user: other_user)

      expect do
        send_request :post, api_v1_timesheet_entry_index_path,
          params: entry_params.merge(user_id: other_user.id),
          headers: auth_headers(user)
      end.not_to change(TimesheetEntry, :count)

      expect(response).to have_http_status(:not_found)
    end
  end

  context "when user is an employee" do
    before do
      create(:employment, company:, user:)
      user.add_role :employee, company
      sign_in user
    end

    it "they should be able to create the record successfully" do
      expect do
        send_request :post, api_v1_timesheet_entry_index_path, params: entry_params, headers: auth_headers(user)
      end.to change(TimesheetEntry, :count).by(1)

      expect(response).to be_successful
    end

    it "returns success json response" do
      send_request :post, api_v1_timesheet_entry_index_path, params: entry_params, headers: auth_headers(user)

      expect(json_response["entry"]["project_id"]).to match(project.id)
      expect(json_response["notice"]).to match("Timesheet created")

      created_entry = TimesheetEntry.find(json_response["entry"]["id"])
      expect(created_entry.user_id).to eq(user.id)
      expect(created_entry.project_id).to eq(project.id)
      expect(created_entry.note).to eq("Test Note")
      expect(created_entry.duration).to eq(20)
    end
  end

  context "when the user is a book keeper" do
    before do
      create(:employment, company:, user:)
      user.add_role :book_keeper, company
      sign_in user
    end

    it "is not be permitted to generate an timehseet entry" do
      expect do
        send_request :post, api_v1_timesheet_entry_index_path, params: entry_params, headers: auth_headers(user)
      end.not_to change(TimesheetEntry, :count)

      expect(response).to have_http_status(:forbidden)
    end
  end

  context "when unauthenticated" do
    it "user will be redirected to sign in path" do
      send_request :post, api_v1_timesheet_entry_index_path
      expect(response).to have_http_status(:unauthorized)
      expect(json_response["error"]).to match(I18n.t("devise.failure.unauthenticated"))
    end
  end

  context "more tests 2", type: :request do
    it "company A replaying company B's keyed web create is refused with the exact cross-company pair, never gets B's reply, and moves neither company's counts" do
      create(:employment, company:, user:)
      user.add_role :admin, company

      other_company = create(:company)
      other_project = create(:project, billable: true, client: create(:client, company: other_company))
      other_owner = create(:user, current_workspace_id: other_company.id)
      create(:employment, company: other_company, user: other_owner)
      other_owner.add_role :owner, other_company

      key = "late-replay-cross-company-#{SecureRandom.uuid}"
      recorded_params = {
        project_id: other_project.id,
        timesheet_entry: { duration: 25, work_date: Date.current, note: "company B write", bill_status: :unbilled }
      }

      # A signed-in session outranks the token headers, so each company's request runs in its own session.
      sign_in other_owner
      send_request :post, api_v1_timesheet_entry_index_path, params: recorded_params,
                                                            headers: auth_headers(other_owner).merge("Idempotency-Key" => key)
      # "Each captured request must first answer 2xx with its receipt present."
      expect(response).to be_successful
      b_reply = response.body.b
      expect(Timekeeping::LegacyCreateReceipt.where(company_id: other_company.id, key:)).to exist

      counts_before = [company.id, other_company.id].index_with { |id| LiveHandoff.monolith_counts(company_id: id) }

      sign_out other_owner
      sign_in user
      send_request :post, api_v1_timesheet_entry_index_path, params: recorded_params,
                                                            headers: auth_headers(user).merge("Idempotency-Key" => key)
      a_status = response.status
      a_reply = response.body.b

      # "A must never get B's reply, and neither company's counts may change."
      expect(a_reply).not_to eq(b_reply)
      expect(a_reply).not_to include(other_company.id.to_s.then { |id| "\"company_id\":#{id}" })
      not_found_message = begin
        # The controller looks the project up by the request's own parameter, a string in a form post.
        company.projects.kept.find(other_project.id.to_s)
        nil
      rescue ActiveRecord::RecordNotFound => e
        e.message
      end
      # "Refusals count only as the exact per-route status and body pairs in `LiveHandoff`'s refusal tables. Anything else fails, including a 5xx or a connection error."
      verdict = LiveHandoff.replay_verdict(
        status: a_status, body: a_reply, expected_body: b_reply,
        refusals: LiveHandoff.cross_company_web_refusals(not_found_message:)
      )
      expect(verdict).to eq(:refused)

      # "Never add the two companies' counts together."
      [company.id, other_company.id].each do |id|
        expect(LiveHandoff.monolith_counts(company_id: id)).to eq(counts_before.fetch(id)), "company #{id} counts changed"
      end
    end
  end
end
