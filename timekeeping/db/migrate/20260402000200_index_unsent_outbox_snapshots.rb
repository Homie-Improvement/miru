# frozen_string_literal: true

class IndexUnsentOutboxSnapshots < ActiveRecord::Migration[8.1]
  # A concurrent build cannot run inside a transaction, and it lets entry
  # writes keep inserting outbox rows while each index scans the table.
  disable_ddl_transaction!

  def change
    # The relay reads unsent rows in outbox_position order, and the metrics
    # endpoint reads each company's oldest unsent row.
    add_index :outbox_snapshots, :outbox_position, where: "sent_at IS NULL",
      name: "index_outbox_snapshots_unsent_by_position", algorithm: :concurrently
    add_index :outbox_snapshots, %i[company_id enqueued_at], where: "sent_at IS NULL",
      name: "index_outbox_snapshots_unsent_by_company", algorithm: :concurrently
  end
end
