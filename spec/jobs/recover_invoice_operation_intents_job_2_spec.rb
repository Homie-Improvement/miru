# frozen_string_literal: true

require "rails_helper"

RSpec.describe RecoverInvoiceOperationIntentsJob, "rows marked undeliverable" do
  it "a recovery run sends no request for an undeliverable row and still delivers an ordinary undelivered row", committed_data: true do
    rows = [SecureRandom.uuid, SecureRandom.uuid].each_with_index.map do |operation_id, index|
      invoice_id = 9801 + index
      InvoiceOperationIntent.create!(
        company_id: 7801, invoice_id:, operation_id:, state: "committed", generation: 1,
        disposition: "active", desired_entry_ids: [81 + index]
      )
      InvoiceOperationOutboxItem.create!(
        company_id: 7801, invoice_id:, operation_id:, kind: "commit",
        payload: { company_id: 7801, invoice_id:, operation_id:, generation: 1, disposition: "active", desired_entry_ids: [81 + index] }
      )
    end
    undeliverable, ordinary = rows
    undeliverable.update_columns(undeliverable_at: Time.current)
    committed = Invoices::ReservationOutcome.new(state: "committed", conflicts: [], counts: {})
    adapter = RecordingReservationAdapter.new(prepare: committed, commit: committed, abort: committed)

    described_class.perform_now(reservations: adapter)

    # "`OutboxDelivery#deliver` and `RecoverInvoiceOperationIntentsJob#deliver_undelivered` skip rows that have `undeliverable_at` set."
    expect(adapter.requests.map(&:operation_id)).to eq([ordinary.operation_id])
    expect(ordinary.reload.delivered_at).to be_present
    expect(undeliverable.reload.delivered_at).to be_nil
    expect(undeliverable.attempts).to eq(0)
  end
end
