# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::TimesheetEntry#destroy", type: :request do
  let(:company) { create(:company) }
  let(:user) { create(:user, email: "timesheet-destroy-#{SecureRandom.hex(6)}@example.com", current_workspace_id: company.id) }
  let(:user2) { create(:user, email: "timesheet-destroy-other-#{SecureRandom.hex(6)}@example.com", current_workspace_id: company.id) }
  let(:client) { create(:client, company:) }
  let(:project) { create(:project, client:) }
  let!(:timesheet_entry) {
    create(:timesheet_entry, user:, project:, work_date: Time.current)
  }

  context "when user is an admin" do
    before do
      create(:employment, company:, user:)
      user.add_role :admin, company
      sign_in user
    end

    it "they should be able to destroy the record successfully" do
      expect do
        send_request :delete, api_v1_timesheet_entry_path(timesheet_entry), headers: auth_headers(user)
      end.not_to change(TimesheetEntry, :count)

      expect(response).to be_successful
    end

    it "returns success json response" do
      send_request :delete, api_v1_timesheet_entry_path(timesheet_entry), headers: auth_headers(user)

      expect(json_response["notice"]).to match("Timesheet deleted")
      expect(timesheet_entry.reload).to be_discarded
    end

    it "does not destroy entries from another workspace" do
      other_company = create(:company)
      other_client = create(:client, company: other_company)
      other_project = create(:project, client: other_client)
      other_entry = create(:timesheet_entry, project: other_project)

      send_request :delete, api_v1_timesheet_entry_path(other_entry), headers: auth_headers(user)

      expect(response).to have_http_status(:not_found)
      expect(other_entry.reload).not_to be_discarded
    end

    it "does not destroy billed entries" do
      timesheet_entry.update_column(:bill_status, TimesheetEntry.bill_statuses[:billed])

      send_request :delete, api_v1_timesheet_entry_path(timesheet_entry), headers: auth_headers(user)

      expect(response).to have_http_status(:forbidden)
      expect(timesheet_entry.reload).not_to be_discarded
    end
  end

  context "when user is an employee" do
    before do
      create(:employment, company:, user:)
      user.add_role :employee, company
      sign_in user
    end

    it "they should be able to destroy the record successfully" do
      expect do
        send_request :delete, api_v1_timesheet_entry_path(timesheet_entry), headers: auth_headers(user)
      end.not_to change(TimesheetEntry, :count)

      expect(response).to be_successful
    end

    it "returns success json response" do
      send_request :delete, api_v1_timesheet_entry_path(timesheet_entry), headers: auth_headers(user)

      expect(json_response["notice"]).to match("Timesheet deleted")
      expect(timesheet_entry.reload).to be_discarded
    end

    context "when entry is older than one week" do
      before do
        timesheet_entry.update!(work_date: 31.days.ago)
      end

      it "returns forbidden" do
        send_request :delete, api_v1_timesheet_entry_path(timesheet_entry), headers: auth_headers(user)

        expect(response).to have_http_status(:forbidden)
        expect(json_response["errors"]).to include("You are not authorized to perform this action.")
      end
    end
  end

  context "when employee tries to delete other user's timesheet entry" do
    before do
      create(:employment, company:, user:)
      user2.add_role :employee, company
      sign_in user2
    end

    it "they should not be able to delete the record" do
      expect do
        send_request :delete, api_v1_timesheet_entry_path(timesheet_entry), headers: auth_headers(user2)
      end.not_to change(TimesheetEntry, :count)

      expect(response).to have_http_status(:forbidden)
    end

    it "returns success json response" do
      send_request :delete, api_v1_timesheet_entry_path(timesheet_entry), headers: auth_headers(user2)

      expect(json_response["errors"]).to include("You are not authorized to perform this action.")
    end
  end

  context "when unauthenticated" do
    it "user will be redirected to sign in path" do
      send_request :delete, api_v1_timesheet_entry_path(timesheet_entry)
      expect(response).to have_http_status(:unauthorized)
      expect(json_response["error"]).to match(I18n.t("devise.failure.unauthenticated"))
    end
  end

  context "more tests 2", type: :request do
  context "with a legacy delete retried after a handoff" do
    before do
      create(:employment, company:, user:)
      user.add_role :admin, company
      sign_in user
    end

    it "answers a legacy web delete retried after cutover, rollback and re-cutover with the stored destroy reply and writes nothing" do
      key = "legacy-destroy-retry-#{SecureRandom.hex(8)}"
      headers = auth_headers(user).merge("Idempotency-Key" => key)
      TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID)
                          .update_columns(owner: "monolith", monolith_store: "legacy", generation: 1, handoff_step: nil)

      send_request :delete, api_v1_timesheet_entry_path(timesheet_entry), headers: headers
      expect(response).to have_http_status(:ok)
      expect(Timekeeping::LegacyEntryWriteReceipt.where(key:, operation: "destroy").count).to eq(1)
      discarded_at = timesheet_entry.reload.discarded_at
      expect(discarded_at).not_to be_nil
      audits_before = Audited::Audit.where(auditable_type: "TimesheetEntry", auditable_id: timesheet_entry.id).count
      receipts_before = Timekeeping::LegacyEntryWriteReceipt.order(:id).pluck(:id, :operation, :fingerprint, :expires_at)
      entries_before = TimesheetEntry.with_discarded.where(user:).count

      handoffs = {
        cutover: { owner: "timekeeping", monolith_store: "legacy", generation: 2 },
        rollback: { owner: "monolith", monolith_store: "prepared", generation: 3 },
        re_cutover: { owner: "timekeeping", monolith_store: "prepared", generation: 4 }
      }
      handoffs.each do |direction, columns|
        TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).update_columns(**columns, handoff_step: nil)

        send_request :delete, api_v1_timesheet_entry_path(timesheet_entry), headers: headers

        # "A legacy-store destroy retried after cutover, rollback or re-cutover is answered from its LegacyEntryWriteReceipt with no forwarded or local second write, and a live late-replay example shows this."
        expect(response).to have_http_status(:ok), "#{direction} answered #{response.status}"
        expect(json_response).to eq("notice" => I18n.t("timesheet_entry.destroy.message"))
        expect(timesheet_entry.reload.discarded_at).to eq(discarded_at)
        expect(Audited::Audit.where(auditable_type: "TimesheetEntry", auditable_id: timesheet_entry.id).count)
          .to eq(audits_before)
        expect(Timekeeping::LegacyEntryWriteReceipt.order(:id).pluck(:id, :operation, :fingerprint, :expires_at))
          .to eq(receipts_before)
        expect(TimesheetEntry.with_discarded.where(user:).count).to eq(entries_before)
      end
    end
  end
  end
end
