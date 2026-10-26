# frozen_string_literal: true

# Receipts of successful entry snapshot deliveries
# (contracts/timekeeping/idempotency.yml, key_sources.entry_snapshots). A relay
# that lost a 200 retries with the same Idempotency-Key and gets the first
# answer back, even after the ownership flip would refuse the batch.
class CreateEntrySnapshotReceipts < ActiveRecord::Migration[8.1]
  def change
    create_table :entry_snapshot_receipts do |t|
      # The sorted set of company ids in the batch: a key reused on another
      # company's batch never matches, so every part of the scope is in the key.
      t.bigint :company_ids, array: true, null: false
      t.string :actor, null: false
      t.string :key, null: false
      t.string :request_digest, null: false
      t.integer :response_status, null: false
      t.jsonb :response_body, null: false, default: {}
      t.datetime :created_at, null: false
      t.datetime :expires_at, null: false

      t.index %i[company_ids actor key], unique: true, name: "index_entry_snapshot_receipts_on_scope_and_key"
      t.index :expires_at
    end
  end
end
