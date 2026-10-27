# frozen_string_literal: true

class AddUndeliverableAtToInvoiceOperationOutboxItems < ActiveRecord::Migration[8.1]
  def change
    # Set when the reservation service refuses a row for a stale generation:
    # resending it can never succeed, so delivery stops retrying it while the
    # row stays undelivered as the record of a settlement still owed.
    add_column :invoice_operation_outbox_items, :undeliverable_at, :datetime
  end
end
