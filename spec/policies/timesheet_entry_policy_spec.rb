# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimesheetEntryPolicy, type: :policy do
  let(:company) { create(:company) }
  let(:company2) { create(:company) }
  let(:user) { create(:user, current_workspace_id: company.id) }
  let(:client) { create(:client, company:) }
  let(:project) { create(:project, client:) }
  let(:scope) { Pundit.policy_scope!(user, TimesheetEntry) }
  # The values the timesheet_entry factory gives, so the entry arranged in the
  # owning store is the one create(:timesheet_entry, project:) made.
  let(:entry_row) do
    { company:, user: create(:user), project:, work_date: Date.current, duration: 480.0, note: "Did that",
      bill_status: "non_billable" }
  end
  let(:timesheet_entry) { arrange_policy_entry }

  subject { described_class }

  # Arranges one entry, with changes applied to entry_row, in the store that
  # owns entries, and returns the record the policy is asked about.
  def arrange_policy_entry(**changes)
    TimesheetEntry.find(arrange_owned_entries([entry_row.merge(changes)]).first)
  end

  context "when user is an admin" do
    before do
      create(:employment, company:, user:)
      user.add_role :admin, company
    end

    permissions :create? do
      it "is permitted to create timesheet entry" do
        expect_owner_state!
        expect(subject).to permit(user, TimesheetEntry)
      end
    end

    permissions :update? do
      it "is permitted to update" do
        entry = timesheet_entry
        expect_owner_state!
        expect(subject).to permit(user, entry)
      end

      it "is permitted to update entries outside the edit window" do
        entry = arrange_policy_entry(work_date: 31.days.ago.to_date)
        expect_owner_state!
        expect(subject).to permit(user, entry)
      end

      it "is not permitted to update billed entries" do
        entry = arrange_policy_entry(bill_status: "billed")
        expect_owner_state!
        expect(subject).not_to permit(user, entry)
      end

      it "is not permitted to update timesheet_entry in different company" do
        entry = timesheet_entry
        client.update(company_id: company2.id)
        expect_owner_state!
        expect(subject).not_to permit(user, entry)
      end
    end

    permissions :show?, :index? do
      it "is permitted to show" do
        entry = timesheet_entry
        expect_owner_state!
        expect(subject).to permit(user, entry)
      end
    end

    permissions :destroy? do
      it "is permitted to destroy" do
        entry = timesheet_entry
        expect_owner_state!
        expect(subject).to permit(user, entry)
      end

      it "is permitted to destroy entries outside the edit window" do
        entry = arrange_policy_entry(work_date: 31.days.ago.to_date)
        expect_owner_state!
        expect(subject).to permit(user, entry)
      end

      it "is not permitted to destroy billed entries" do
        entry = arrange_policy_entry(bill_status: "billed")
        expect_owner_state!
        expect(subject).not_to permit(user, entry)
      end

      it "is not permitted to destroy timesheet_entry in different company" do
        entry = timesheet_entry
        client.update(company_id: company2.id)
        expect_owner_state!
        expect(subject).not_to permit(user, entry)
      end
    end

    describe "scope" do
      it "allows current workspace timesheet entries" do
        entry = timesheet_entry
        expect_owner_state!
        expect(scope.to_a).to match_array([entry])
      end
    end
  end

  context "when user is an employee" do
    before do
      create(:employment, company:, user:)
      user.add_role :employee, company
    end

    permissions :create? do
      it "is permitted to create timesheet_entry" do
        expect_owner_state!
        expect(subject).to permit(user, TimesheetEntry)
      end
    end

    permissions :update? do
      context "when entry belongs to same user" do
        let(:entry_row) { super().merge(user:) }

        context "when entry is not billed" do
          it "is permitted to update the entry" do
            entry = timesheet_entry
            expect_owner_state!
            expect(subject).to permit(user, entry)
          end

          it "is not permitted to update entries outside the edit window" do
            entry = arrange_policy_entry(work_date: 31.days.ago.to_date)
            expect_owner_state!
            expect(subject).not_to permit(user, entry)
          end

          it "is permitted to update an entry exactly at the boundary (work_date == cutoff)" do
            # work_date < edit_days.days.ago is strict less-than, so the boundary day is editable
            entry = arrange_policy_entry(work_date: 30.days.ago.to_date)
            expect_owner_state!
            expect(subject).to permit(user, entry)
          end

          it "is not permitted when company has a custom edit window and entry exceeds it" do
            company.update!(timesheet_edit_days: 7)
            entry = arrange_policy_entry(work_date: 8.days.ago.to_date)
            expect_owner_state!
            expect(subject).not_to permit(user, entry)
          end

          it "is permitted when company has a custom edit window and entry is within it" do
            company.update!(timesheet_edit_days: 7)
            entry = arrange_policy_entry(work_date: 6.days.ago.to_date)
            expect_owner_state!
            expect(subject).to permit(user, entry)
          end
        end

        context "when entry is billed" do
          let(:timesheet_entry) { arrange_policy_entry(bill_status: "billed") }

          it "is not permitted to update the entry" do
            entry = timesheet_entry
            expect_owner_state!
            expect(subject).not_to permit(user, entry)
          end
        end
      end

      it "is not permitted to update" do
        entry = timesheet_entry
        expect_owner_state!
        expect(subject).not_to permit(user, entry)
      end

      it "is not permitted to update timesheet_entry in different company" do
        entry = timesheet_entry
        client.update(company_id: company2.id)
        expect_owner_state!
        expect(subject).not_to permit(user, entry)
      end
    end

    permissions :show?, :index? do
      it "is permitted to show" do
        entry = timesheet_entry
        expect_owner_state!
        expect(subject).to permit(user, entry)
      end
    end

    permissions :destroy? do
      it "is not permitted to destroy" do
        entry = timesheet_entry
        expect_owner_state!
        expect(subject).not_to permit(user, entry)
      end

      it "is not permitted to destroy own entries outside the edit window" do
        entry = arrange_policy_entry(user:, work_date: 31.days.ago.to_date)
        expect_owner_state!
        expect(subject).not_to permit(user, entry)
      end

      it "is not permitted to destroy client in different company" do
        entry = timesheet_entry
        client.update(company_id: company2.id)
        expect_owner_state!
        expect(subject).not_to permit(user, entry)
      end
    end

    describe "scope" do
      it "allows timesheet entries only for the user" do
        user1 = create(:user, current_workspace_id: company.id)
        own_entry_id, other_entry_id = arrange_owned_entries([entry_row.merge(user:), entry_row.merge(user: user1)])
        own_entry = TimesheetEntry.find(own_entry_id)
        other_entry = TimesheetEntry.find(other_entry_id)

        expect_owner_state!
        expect(scope.to_a).to match_array([own_entry])
        expect(scope.to_a).not_to include(other_entry)
      end
    end
  end

  context "when user is an owner" do
    before do
      create(:employment, company:, user:)
      user.add_role :owner, company
    end

    permissions :update?, :destroy? do
      it "permits recent entries" do
        entry = timesheet_entry
        expect_owner_state!
        expect(subject).to permit(user, entry)
      end

      it "permits entries outside the edit window (owners bypass the window)" do
        entry = arrange_policy_entry(work_date: 31.days.ago.to_date)
        expect_owner_state!
        expect(subject).to permit(user, entry)
      end

      it "does not permit billed entries" do
        entry = arrange_policy_entry(bill_status: "billed")
        expect_owner_state!
        expect(subject).not_to permit(user, entry)
      end
    end
  end
end
