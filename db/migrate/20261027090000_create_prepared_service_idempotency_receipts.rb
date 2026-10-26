# frozen_string_literal: true

# The prepared monolith's copy of Timekeeping's service_idempotency_receipts
# (timekeeping/db/migrate/20260601000000_create_invoice_operations.rb): the
# stored 2xx answers of commit, abort, mark_billed and detach_entries, keyed by
# the calling service's name.
#
# Service receipts get their own table because idempotency_records must keep
# the exact shape of Timekeeping's idempotency_receipts, which the cutover
# checkpoint loads it into, and that table has a NOT NULL actor_id a service
# does not have. Every key column is NOT NULL because PostgreSQL treats NULLs
# as distinct in a unique index.
class CreatePreparedServiceIdempotencyReceipts < ActiveRecord::Migration[8.1]
  def change
    create_table :service_idempotency_receipts do |t|
      t.bigint :company_id, null: false
      t.string :actor_name, null: false
      t.string :operation, null: false
      t.string :key, null: false
      t.string :fingerprint, null: false
      t.integer :status, null: false
      t.text :body, null: false
      t.datetime :created_at, null: false

      t.index %i[company_id actor_name operation key], unique: true,
        name: "index_service_idempotency_receipts_on_receipt_key"
    end
  end
end
