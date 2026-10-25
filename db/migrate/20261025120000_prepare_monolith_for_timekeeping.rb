# frozen_string_literal: true

# Step S2 of docs/architecture/timekeeping-soa.md section 10.2. It adds the
# entry company and version columns, the ownership record, the invoice
# operation ledger and the prepared monolith's local tables. Nothing writes the
# new tables yet, and the monolith keeps writing timesheet_entries as before.
class PrepareMonolithForTimekeeping < ActiveRecord::Migration[8.1]
  OWNERS = %w[monolith timekeeping].freeze
  HANDOFF_STEPS = %w[close_admission settle freeze checkpoint sequence reconcile].freeze

  def change
    add_entry_columns
    create_timekeeping_ownership
    create_invoice_operation_intents
    create_prepared_entries_and_reservations
    create_prepared_invoice_operations
    create_prepared_entry_audits
    create_prepared_idempotency_records
    create_prepared_entry_outbox_items
  end

  private

    def add_entry_columns
      # Nullable: a NOT NULL would turn a write that bypasses the model into an
      # error. TimesheetEntry stamps it on every save that needs it, and the
      # next migration fills existing rows outside this transaction, so the
      # table lock add_column takes is released before any row is rewritten.
      add_column :timesheet_entries, :company_id, :bigint
      add_column :timesheet_entries, :version, :integer, null: false, default: 0
    end

    # docs/architecture/timekeeping-soa.md section 10.1. One row for all
    # companies, so it has no company_id. The column defaults hold the initial
    # state, generation 1 owned by the monolith, and id = 1 allows one row only.
    def create_timekeeping_ownership
      create_table :timekeeping_ownership do |t|
        t.bigint :generation, null: false, default: 1
        t.string :owner, null: false, default: "monolith"
        t.string :handoff_step
        t.datetime :changed_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
        t.string :changed_by, null: false, default: "system"

        t.check_constraint "id = 1", name: "timekeeping_ownership_single_row_check"
        t.check_constraint "owner IN (#{quoted_list(OWNERS)})", name: "timekeeping_ownership_owner_check"
        t.check_constraint "handoff_step IS NULL OR handoff_step IN (#{quoted_list(HANDOFF_STEPS)})",
          name: "timekeeping_ownership_handoff_step_check"
      end

      reversible do |direction|
        # Inserts into a table this migration just created, so it locks nothing in use.
        direction.up do
          safety_assured { execute "INSERT INTO timekeeping_ownership (id) VALUES (1) ON CONFLICT (id) DO NOTHING" }
        end
      end
    end

    # Section 9.2. invoice_id has no foreign key, so an intent outlives a
    # deleted invoice.
    def create_invoice_operation_intents
      create_table :invoice_operation_intents do |t|
        t.bigint :company_id, null: false
        t.bigint :invoice_id, null: false
        t.uuid :operation_id, null: false
        t.string :state, null: false
        t.bigint :generation, null: false
        t.datetime :created_at, null: false
        t.datetime :finished_at

        t.index %i[company_id invoice_id operation_id], unique: true,
          name: "index_invoice_operation_intents_on_company_invoice_operation"
        t.check_constraint "state IN ('pending', 'committed', 'failed')", name: "invoice_operation_intents_state_check"
      end
    end

    # The same two tables as timekeeping/db/migrate/20260101000000_create_entries_and_reservations.rb,
    # so a checkpoint loads into either application unchanged.
    def create_prepared_entries_and_reservations
      create_table :entries do |t|
        t.bigint :company_id, null: false
        t.integer :version, null: false, default: 1
        t.bigint :project_id, null: false
        t.bigint :user_id, null: false
        t.bigint :agent_id
        t.date :work_date, null: false
        t.float :duration, null: false
        t.text :note, default: ""
        t.string :bill_status, null: false
        t.string :review_status, null: false, default: "not_required"
        t.boolean :locked, default: false
        t.string :source, null: false, default: "manual"
        t.jsonb :source_metadata, null: false, default: {}
        t.string :external_run_id
        t.string :external_session_id
        t.text :proof_url
        t.jsonb :proof_metadata, null: false, default: {}
        t.datetime :discarded_at
        t.timestamps

        t.index %i[company_id id], unique: true
        t.index %i[company_id user_id work_date]
        t.index %i[company_id project_id work_date]
      end

      create_table :reservations, id: false do |t|
        t.bigint :company_id, null: false
        t.bigint :entry_id, null: false
        t.bigint :invoice_id, null: false
        t.string :state, null: false
        t.string :disposition, null: false
        t.uuid :operation_id, null: false
        t.datetime :created_at, null: false

        t.index %i[company_id entry_id], name: "index_reservations_on_company_id_and_entry_id"
        t.index %i[company_id entry_id], unique: true, where: "state = 'committed'",
          name: "index_reservations_one_committed_per_entry"
        t.index %i[company_id entry_id], unique: true, where: "state = 'provisional'",
          name: "index_reservations_one_provisional_per_entry"
        t.check_constraint "state IN ('provisional', 'committed')", name: "reservations_state_check"
        t.check_constraint "disposition IN ('active', 'retained')", name: "reservations_disposition_check"
        # Composite, so a reservation can only point at an entry of its own company.
        t.foreign_key :entries, column: %i[company_id entry_id], primary_key: %i[company_id id]
      end
    end

    # Section 7.2: the terminal record of each prepare, commit or abort.
    def create_prepared_invoice_operations
      create_table :invoice_operations do |t|
        t.bigint :company_id, null: false
        t.bigint :invoice_id, null: false
        t.uuid :operation_id, null: false
        t.string :state, null: false
        t.bigint :desired_entry_ids, array: true, null: false, default: []
        t.string :disposition, null: false
        t.bigint :generation, null: false
        t.datetime :created_at, null: false
        t.datetime :finished_at

        # At most one unresolved operation per invoice.
        t.index %i[company_id invoice_id], unique: true, where: "state = 'prepared'",
          name: "index_invoice_operations_one_prepared_per_invoice"
        t.check_constraint "state IN ('prepared', 'committed', 'aborted')", name: "invoice_operations_state_check"
        t.check_constraint "disposition IN ('active', 'retained')", name: "invoice_operations_disposition_check"
      end
    end

    # Section 6.4: who changed which entry fields. Named entry_audits because
    # the audited gem already owns the audits table.
    def create_prepared_entry_audits
      create_table :entry_audits do |t|
        t.bigint :company_id, null: false
        t.bigint :entry_id, null: false
        t.string :actor_type, null: false
        t.string :actor_id
        t.string :action, null: false
        t.jsonb :changed_fields, null: false, default: {}
        t.datetime :created_at, null: false

        t.index %i[company_id entry_id]
        t.foreign_key :entries, column: %i[company_id entry_id], primary_key: %i[company_id id]
      end
    end

    # Section 5.1: receipts of successful entry API writes. A key from another
    # company or actor never matches, so every part of the scope is in the key.
    def create_prepared_idempotency_records
      create_table :idempotency_records do |t|
        t.bigint :company_id, null: false
        t.string :actor_type, null: false
        t.string :actor_id, null: false
        t.string :operation, null: false
        t.string :key, null: false
        t.string :request_digest, null: false
        t.integer :response_status, null: false
        t.jsonb :response_body, null: false, default: {}
        t.datetime :created_at, null: false
        t.datetime :expires_at, null: false

        t.index %i[company_id actor_type actor_id operation key], unique: true,
          name: "index_idempotency_records_on_scope_and_key"
        t.index :expires_at
      end
    end

    # Section 5.4: entry snapshots waiting for the relay. outbox_position is
    # one order across every company, as the relay delivers it, so it is the
    # primary key rather than a per-company key.
    def create_prepared_entry_outbox_items
      create_table :entry_outbox_items, primary_key: :outbox_position do |t|
        t.bigint :company_id, null: false
        t.bigint :generation, null: false
        t.bigint :entry_id, null: false
        t.jsonb :payload, null: false
        t.datetime :created_at, null: false
        t.datetime :sent_at

        t.index %i[company_id entry_id]
      end
    end

    def quoted_list(values)
      values.map { |value| connection.quote(value) }.join(", ")
    end
end
