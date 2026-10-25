# frozen_string_literal: true

class CreateWriteTables < ActiveRecord::Migration[8.1]
  def change
    # One row per entry change, written in the same transaction as the change.
    # before is null for a create; entry_created_at keeps the entry's original
    # created_at.
    create_table :audit_events do |t|
      t.bigint :company_id, null: false
      t.bigint :entry_id, null: false
      t.string :actor_type, null: false
      t.bigint :actor_id, null: false
      t.string :action, null: false
      t.jsonb :before
      t.jsonb :after, null: false
      t.datetime :entry_created_at, null: false
      t.datetime :created_at, null: false

      t.index %i[company_id entry_id]
    end

    # The entry snapshot outbox. Its columns are exactly
    # contracts/timekeeping/entry_snapshots.yml entry_fields plus generation and
    # outbox_position, so a row carries ids and never a name, email or token.
    # id is the entry's id; outbox_position is the sequence-backed key the
    # relay delivers in order. A rolled-back write leaves a gap in positions.
    create_table :outbox_snapshots, primary_key: :outbox_position do |t|
      t.bigint :id, null: false
      t.bigint :project_id, null: false
      t.bigint :user_id, null: false
      t.bigint :agent_id
      t.date :work_date, null: false
      t.float :duration, null: false
      t.text :note
      t.string :bill_status, null: false
      t.string :review_status, null: false
      t.boolean :locked, null: false
      t.string :source, null: false
      t.jsonb :source_metadata, null: false
      t.string :external_run_id
      t.string :external_session_id
      t.text :proof_url
      t.jsonb :proof_metadata, null: false
      t.datetime :discarded_at
      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false
      t.bigint :company_id, null: false
      t.integer :version, null: false
      t.bigint :generation, null: false

      t.index %i[company_id id]
    end

    # One row per company. A write reads its own company's row FOR SHARE and
    # compares it with the Ownership-Generation header.
    # default: nil keeps the key free of a sequence: it is the company's id.
    create_table :ownership_generations, primary_key: :company_id, id: :bigint, default: nil do |t|
      t.bigint :generation, null: false
    end

    # Stored 2xx answers. Every column of the receipt key is NOT NULL, because
    # PostgreSQL treats NULLs as distinct in a unique index and the index would
    # then let a duplicate receipt in. body holds the exact JSON that is replayed.
    create_table :idempotency_receipts do |t|
      t.bigint :company_id, null: false
      t.string :actor_type, null: false
      t.bigint :actor_id, null: false
      t.string :operation, null: false
      t.string :key, null: false
      t.string :fingerprint, null: false
      t.integer :status, null: false
      t.text :body, null: false
      t.datetime :created_at, null: false

      t.index %i[company_id actor_type actor_id operation key], unique: true,
        name: "index_idempotency_receipts_on_receipt_key"
    end
  end
end
