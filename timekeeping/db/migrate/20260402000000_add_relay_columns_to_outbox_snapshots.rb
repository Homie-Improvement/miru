# frozen_string_literal: true

class AddRelayColumnsToOutboxSnapshots < ActiveRecord::Migration[8.1]
  def change
    # The relay's own bookkeeping, kept beside the snapshot columns. Neither
    # column is part of the snapshot: the relay builds each payload entry from
    # Timekeeping::OutboxFields::ENTRY_FIELDS only.
    #
    # enqueued_at is when the outbox row was written. The database fills it in
    # the entry write's own transaction, because the row's created_at and
    # updated_at are the entry's copied values and would misstate outbox lag.
    # sent_at is null until the projection endpoint answers 200 for the batch
    # that carried the row.
    add_column :outbox_snapshots, :enqueued_at, :datetime, null: false, default: -> { "CURRENT_TIMESTAMP" }
    add_column :outbox_snapshots, :sent_at, :datetime

    # The relay reads unsent rows in outbox_position order, and the metrics
    # endpoint reads each company's oldest unsent row.
    add_index :outbox_snapshots, :outbox_position, where: "sent_at IS NULL",
      name: "index_outbox_snapshots_unsent_by_position"
    add_index :outbox_snapshots, %i[company_id enqueued_at], where: "sent_at IS NULL",
      name: "index_outbox_snapshots_unsent_by_company"
  end
end
