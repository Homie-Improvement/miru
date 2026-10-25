# frozen_string_literal: true

class CreateEntriesAndReservations < ActiveRecord::Migration[8.1]
  def change
    # The columns of contracts/timekeeping/entry_snapshots.yml entry_fields.
    # The id is the monolith's entry id, so a snapshot import keeps it.
    create_table :entries do |t|
      t.bigint :company_id, null: false
      t.integer :version, null: false, default: 1
      t.bigint :project_id, null: false
      t.bigint :user_id, null: false
      t.bigint :agent_id
      t.date :work_date, null: false
      t.float :duration, null: false
      t.text :note, default: ""
      # Stored as the contract's strings ("unbilled", "not_required"), not the
      # monolith's integer enum codes.
      t.string :bill_status, null: false
      t.string :review_status, null: false, default: "not_required"
      # Kept because the snapshot carries it. Reads never use it: an entry is
      # locked exactly when a reservations row exists for it.
      t.boolean :locked, default: false
      t.string :source, null: false, default: "manual"
      t.jsonb :source_metadata, null: false, default: {}
      t.string :external_run_id
      t.string :external_session_id
      t.text :proof_url
      t.jsonb :proof_metadata, null: false, default: {}
      # A tombstone: a discarded entry keeps its row.
      t.datetime :discarded_at
      t.timestamps

      # The target of the reservations foreign key, which must name the company.
      t.index %i[company_id id], unique: true
      t.index %i[company_id user_id work_date]
      t.index %i[company_id project_id work_date]
    end

    # docs/architecture/timekeeping-soa.md section 7.2. invoice_id has no
    # foreign key: the invoice lives in the monolith's database.
    create_table :reservations, id: false do |t|
      t.bigint :company_id, null: false
      t.bigint :entry_id, null: false
      t.bigint :invoice_id, null: false
      t.string :state, null: false
      t.string :disposition, null: false
      t.uuid :operation_id, null: false
      t.datetime :created_at, null: false

      # Serves the locked lookup, which has no state condition and so cannot
      # use the partial indexes below, and the foreign key's referencing side.
      t.index %i[company_id entry_id], name: "index_reservations_on_company_id_and_entry_id"
      t.index %i[company_id entry_id], unique: true, where: "state = 'committed'",
        name: "index_reservations_one_committed_per_entry"
      t.index %i[company_id entry_id], unique: true, where: "state = 'provisional'",
        name: "index_reservations_one_provisional_per_entry"
      t.check_constraint "state IN ('provisional', 'committed')", name: "reservations_state_check"
      t.check_constraint "disposition IN ('active', 'retained')", name: "reservations_disposition_check"
    end

    # Composite, so a reservation can only point at an entry of its own company.
    add_foreign_key :reservations, :entries, column: %i[company_id entry_id], primary_key: %i[company_id id]
  end
end
