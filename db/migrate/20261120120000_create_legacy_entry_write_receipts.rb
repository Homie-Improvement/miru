# frozen_string_literal: true

# Receipts of timesheet entry updates and deletes written while the monolith's
# original legacy store owns entries. A client that lost the answer to a
# committed update or delete retries with the same Idempotency-Key and gets
# the first answer back, instead of writing the entry and its audit row again.
#
# These rows live apart from legacy_create_receipts: the first cutover reads
# every row of that table as a create receipt, and its unique index has no
# operation, so a create and an update under one key would collide there.
class CreateLegacyEntryWriteReceipts < ActiveRecord::Migration[8.1]
  def change
    create_table :legacy_entry_write_receipts do |t|
      t.bigint :company_id, null: false
      t.string :actor_kind, null: false
      t.bigint :actor_id, null: false
      # "update" or "destroy"; part of the scope, so one key used for both
      # operations keeps a receipt for each.
      t.string :operation, null: false
      t.string :key, null: false
      t.string :fingerprint, null: false
      # No foreign key: the receipt keeps answering after its entry is
      # discarded or moves to another store.
      t.bigint :timesheet_entry_id, null: false
      # The entry's stored values as the write committed them, so a replay
      # answers what the first attempt answered, never later edits.
      t.jsonb :entry_attributes, null: false
      t.datetime :created_at, null: false
      # A client retries only for a short while, so a receipt, and the copy of
      # the entry it holds, is pruned once this time has passed.
      t.datetime :expires_at, null: false

      t.index %i[company_id actor_kind actor_id operation key], unique: true,
                                                                name: "index_legacy_entry_write_receipts_on_scope_and_key"
      t.index :expires_at
    end
  end
end
