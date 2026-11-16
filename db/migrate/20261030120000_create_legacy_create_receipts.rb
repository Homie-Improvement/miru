# frozen_string_literal: true

# Receipts of timesheet entry creates written while the monolith's original
# legacy store owns entries. A client that lost the answer to a committed
# create retries with the same Idempotency-Key and gets the first answer back,
# instead of recording the same time twice.
#
# These rows live apart from idempotency_records: the handoff copies, loads and
# reconciles that table, and the prepared tables must stay empty until a
# rollback loads a checkpoint into them.
class CreateLegacyCreateReceipts < ActiveRecord::Migration[8.1]
  def change
    create_table :legacy_create_receipts do |t|
      t.bigint :company_id, null: false
      t.string :actor_kind, null: false
      t.bigint :actor_id, null: false
      t.string :key, null: false
      t.string :fingerprint, null: false
      # No foreign key: the receipt keeps answering after its entry is
      # deleted or moves to another store.
      t.bigint :timesheet_entry_id, null: false
      # The entry's stored values as the create committed them, so a replay
      # answers what the first attempt answered, never later edits.
      t.jsonb :entry_attributes, null: false
      t.datetime :created_at, null: false

      t.index %i[company_id actor_kind actor_id key], unique: true,
                                                      name: "index_legacy_create_receipts_on_scope_and_key"
    end
  end
end
