# frozen_string_literal: true

class IndexUnsentEntryOutboxItems < ActiveRecord::Migration[8.1]
  # A concurrent build cannot run inside a transaction, and it lets entry
  # writes keep inserting outbox rows while the index scans the table.
  disable_ddl_transaction!

  def change
    # The relay reads each company's unsent rows in outbox_position order.
    add_index :entry_outbox_items, %i[company_id outbox_position], where: "sent_at IS NULL",
      name: "index_entry_outbox_items_unsent_by_company", algorithm: :concurrently
  end
end
