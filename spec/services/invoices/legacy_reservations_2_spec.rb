# frozen_string_literal: true

require "rails_helper"

RSpec.describe Invoices::LegacyReservations do
  let(:failed_billing_company) { create(:company) }
  let(:failed_billing_client) { create(:client, company: failed_billing_company) }
  let(:failed_billing_project) { create(:project, client: failed_billing_client, billable: true) }
  let(:failed_billing_user) { create(:user, current_workspace_id: failed_billing_company.id) }

  it "a failing mark_billed raises its own validation error and the caller's writer mark is back afterwards" do
    entry = create(:timesheet_entry, user: failed_billing_user, project: failed_billing_project, bill_status: "unbilled")
    entry.update_columns(duration: -5)
    request = Invoices::ReservationRequest.new(
      company_id: failed_billing_company.id, invoice_id: 700_104, operation_id: SecureRandom.uuid,
      generation: TimekeepingOwnership.current.generation, disposition: "active", entries: [entry.id]
    )
    connection = ActiveRecord::Base.connection
    raised = nil

    seen_after = ApplicationRecord.transaction do
      connection.execute("SET LOCAL miru.writer = 'caller_mark'")
      begin
        described_class.new.mark_billed(request)
      rescue ActiveRecord::RecordInvalid => error
        raised = error
      end
      connection.select_value("SELECT current_setting('miru.writer', true)")
    end

    # "A failing mark_billed raises its own original error and the caller's mark is restored afterwards"
    expect(raised).to be_a(ActiveRecord::RecordInvalid)
    expect(seen_after).to eq("caller_mark")
    expect(entry.reload.bill_status).to eq("unbilled")
  end
end
