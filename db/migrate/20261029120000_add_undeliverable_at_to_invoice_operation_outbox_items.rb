# frozen_string_literal: true

class AddUndeliverableAtToInvoiceOperationOutboxItems < ActiveRecord::Migration[8.1]
  def change
    # Set when the service refuses a delivery for good (a stale ownership
    # generation), so delivery and recovery stop re-sending the row while it
    # stays in place for an operator. Nullable with no backfill: every
    # existing row stays deliverable.
    add_column :invoice_operation_outbox_items, :undeliverable_at, :datetime
  end
end
