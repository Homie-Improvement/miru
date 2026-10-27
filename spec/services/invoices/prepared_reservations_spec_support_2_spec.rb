# frozen_string_literal: true

require "rails_helper"

RSpec.describe PreparedReservationsSpecSupport do
  include PreparedReservationsSpecSupport

  before { prepare_local_ownership! }

  # "Add prepared_spec_projected_entry(company) to the support module and use it in place of
  # prepared_save_spec_entry, the inline Array.new builder and prepared_e2e_entry."
  # Invoice lines reference the timesheet row while the adapter reads the prepared
  # entries table, so both must exist under one id with matching fields.
  it "prepared_spec_projected_entry returns the timesheet row with a prepared entry under the same id" do
    company = create(:company)

    row = prepared_spec_projected_entry(company)

    expect(row).to be_a(TimesheetEntry)
    expect(row.bill_status).to eq("unbilled")
    prepared = Timekeeping::LocalEntry.find_by!(id: row.id)
    expect(prepared.company_id).to eq(company.id)
    expect(prepared.user_id).to eq(row.user_id)
    expect(prepared.project_id).to eq(row.project_id)
    expect(prepared.work_date).to eq(row.work_date)
    expect(prepared.duration).to eq(row.duration)
    expect(prepared.bill_status).to eq("unbilled")
    expect(User.find(row.user_id).current_workspace_id).to eq(company.id)
    project = Project.find(row.project_id)
    expect(project.billable).to be(true)
    expect(project.client.company_id).to eq(company.id)
  end
end
