# frozen_string_literal: true

require "rails_helper"

# Pins today's timesheet entry rules: the bulk move and bulk delete (A9, A10), agent
# entry ownership (S7) and whose entry an owner, admin or employee may create. Every
# example reads the rows it checks from the store that owns entries in the selected
# ownership state, so it pins the stored end state.
#
# The live Timekeeping app reads company, user and project rows on its own database
# connections, so in the timekeeping state the rows must be committed.
RSpec.describe "Characterization: timesheet entry rules", type: :request, committed_data: true do
  let(:company) { create(:company) }
  let(:client) { create(:client, company:) }
  let(:project) { create(:project, client:, billable: true) }
  let(:other_project) { create(:project, client:, billable: true) }

  def rules_spec_member(role)
    member = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user: member)
    member.add_role role, company
    member
  end

  # A row for arrange_owned_entries with the factory's duration and note, dated today
  # and unbilled.
  def rules_spec_row(user:, locked:, project: self.project)
    { company:, user:, project:, work_date: Date.current, duration: 480.0, note: "Did that",
      bill_status: "unbilled", locked: }
  end

  # Every entry the owning store holds, discarded ones included, so a count keeps the
  # reach of a count over the whole table.
  def rules_spec_owned_entry_count
    owned_entries(state: TimekeepingOwnerState.current, include_discarded: true).size
  end

  describe "A9: bulk move ignores `locked` and skips a failing entry silently" do
    it "returns 200 for an employee, moves the unlocked entry and silently keeps the locked one" do
      employee = rules_spec_member(:employee)
      create(:project_member, project:, user: employee)
      create(:project_member, project: other_project, user: employee)
      locked_entry_id, unlocked_entry_id = arrange_owned_entries(
        [rules_spec_row(user: employee, locked: true), rules_spec_row(user: employee, locked: false)]
      )

      sign_in employee
      expect_owner_state!
      send_request :patch, api_v1_bulk_action_path,
        params: { ids: [locked_entry_id, unlocked_entry_id], project_id: other_project.id },
        headers: auth_headers(employee)

      expect(response).to have_http_status(:ok)
      # Silent: the response reports success and carries no error for the skipped entry.
      expect(json_response["notice"]).to eq(I18n.t("timesheet_entry.update.message"))
      expect(json_response).not_to have_key("error")
      expect(json_response).not_to have_key("errors")

      moved = owned_entry(unlocked_entry_id, state: TimekeepingOwnerState.current)
      expect(moved.fetch("project_id")).to eq(other_project.id)
      expect(moved.fetch("locked")).to be(false)
      expect(moved.fetch("bill_status")).to eq("unbilled")

      skipped = owned_entry(locked_entry_id, state: TimekeepingOwnerState.current)
      expect(skipped.fetch("project_id")).to eq(project.id)
      expect(skipped.fetch("locked")).to be(true)
      expect(skipped.fetch("bill_status")).to eq("unbilled")
    end

    it "moves a locked entry for an admin" do
      admin = rules_spec_member(:admin)
      locked_entry_id, = arrange_owned_entries([rules_spec_row(user: admin, locked: true)])

      sign_in admin
      expect_owner_state!
      send_request :patch, api_v1_bulk_action_path,
        params: { ids: [locked_entry_id], project_id: other_project.id },
        headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)

      moved = owned_entry(locked_entry_id, state: TimekeepingOwnerState.current)
      expect(moved.fetch("project_id")).to eq(other_project.id)
      expect(moved.fetch("locked")).to be(true)
      expect(moved.fetch("bill_status")).to eq("unbilled")
    end
  end

  describe "A10: bulk delete skips the locked-entry edit rule" do
    it "discards an employee's locked entry inside the edit window" do
      employee = rules_spec_member(:employee)
      create(:project_member, project:, user: employee)
      locked_entry_id, = arrange_owned_entries([rules_spec_row(user: employee, locked: true)])

      sign_in employee
      expect_owner_state!
      send_request :delete, api_v1_bulk_action_path,
        params: { source: { ids: [locked_entry_id] } },
        headers: auth_headers(employee)

      expect(response).to have_http_status(:ok)

      discarded = owned_entry(locked_entry_id, state: TimekeepingOwnerState.current)
      expect(discarded.fetch("discarded_at")).to be_present
      expect(discarded.fetch("locked")).to be(true)
      expect(discarded.fetch("bill_status")).to eq("unbilled")
    end
  end

  describe "S7: an agent entry belongs to the agent's company and user" do
    let(:agent_user) { rules_spec_member(:employee) }
    let(:agent) { create(:agent, company:, user: agent_user, default_project: project, provider: "codex") }
    let(:agent_token) { AgentKey.issue_for(agent:, name: "Characterization Key", created_by: agent_user).last }

    before { create(:project_member, project:, user: agent_user) }

    def agent_entry_request_with_user_override(other_user, inside_entry_payload:)
      entry_params = { project_id: project.id, duration_minutes: 30, work_date: Date.current.iso8601 }
      params = { timesheet_entry: entry_params }
      if inside_entry_payload
        entry_params[:user_id] = other_user.id
      else
        params[:user_id] = other_user.id
      end

      send_request :post, api_v1_agent_timesheet_entries_path, params:,
        headers: { "Authorization" => "Bearer #{agent_token}" }
    end

    { "inside the timesheet_entry payload" => true, "at the top level" => false }.each do |placement, inside|
      it "ignores a user_id supplied #{placement} and saves the entry for the agent's user" do
        other_user = rules_spec_member(:employee)
        agent_token

        expect_owner_state!
        agent_entry_request_with_user_override(other_user, inside_entry_payload: inside)

        expect(response).to have_http_status(:ok)

        entry = owned_entry(json_response.dig("entry", "id"), state: TimekeepingOwnerState.current)
        expect(entry.fetch("user_id")).to eq(agent_user.id)
        expect(entry.fetch("agent_id")).to eq(agent.id)
        expect(entry.fetch("company_id")).to eq(company.id)
        expect(entry.fetch("locked")).to be(false)
        expect(entry.fetch("bill_status")).to eq("unbilled")
      end
    end

    it "refuses a project from another company and creates no entry" do
      foreign_project = create(:project, client: create(:client, company: create(:company)), billable: true)
      agent_token

      expect_owner_state!
      expect do
        send_request :post, api_v1_agent_timesheet_entries_path, params: {
          timesheet_entry: { project_id: foreign_project.id, duration_minutes: 30, work_date: Date.current.iso8601 }
        }, headers: { "Authorization" => "Bearer #{agent_token}" }
      end.not_to change { rules_spec_owned_entry_count }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "S7 model rule: validate_agent_belongs_to_workspace", type: :model do
    it "rejects an entry whose user is not the agent's user" do
      agent_user = rules_spec_member(:employee)
      other_user = rules_spec_member(:employee)
      agent = create(:agent, company:, user: agent_user, default_project: project, provider: "codex")

      entry = build(:timesheet_entry, project:, user: other_user, agent:, bill_status: "unbilled")

      expect_owner_state!
      expect(entry).not_to be_valid
      expect(entry.errors[:user]).to include("must match the agent user")
    end

    it "rejects an entry on a project of another company than the agent's" do
      agent_user = rules_spec_member(:employee)
      agent = create(:agent, company:, user: agent_user, default_project: project, provider: "codex")
      foreign_project = create(:project, client: create(:client, company: create(:company)), billable: true)

      entry = build(:timesheet_entry, project: foreign_project, user: agent_user, agent:, bill_status: "unbilled")

      expect_owner_state!
      expect(entry).not_to be_valid
      expect(entry.errors[:agent]).to include("must belong to the same company")
    end
  end

  describe "creating an entry for another user through timesheet_entry_user" do
    let(:target_user) { rules_spec_member(:employee) }

    def create_entry_request(actor, user_id)
      send_request :post, api_v1_timesheet_entry_index_path, params: {
        project_id: project.id,
        timesheet_entry: { duration: 20, work_date: Date.current, note: "Characterization", bill_status: :unbilled },
        user_id:
      }, headers: auth_headers(actor)
    end

    [:owner, :admin].each do |role|
      it "lets an #{role} create an entry for a same-company user" do
        actor = rules_spec_member(role)
        project
        target_user
        sign_in actor

        expect_owner_state!
        expect { create_entry_request(actor, target_user.id) }.to change { rules_spec_owned_entry_count }.by(1)
        expect(response).to have_http_status(:ok)

        entry = owned_entry(json_response.dig("entry", "id"), state: TimekeepingOwnerState.current)
        expect(entry.fetch("user_id")).to eq(target_user.id)
        expect(entry.fetch("locked")).to be(false)
        expect(entry.fetch("bill_status")).to eq("unbilled")
      end
    end

    it "refuses an employee who targets another user and creates no entry" do
      employee = rules_spec_member(:employee)
      create(:project_member, project:, user: employee)
      target_user
      sign_in employee

      expect_owner_state!
      expect { create_entry_request(employee, target_user.id) }.not_to change { rules_spec_owned_entry_count }
      expect(response).to have_http_status(:forbidden)
    end
  end
end
