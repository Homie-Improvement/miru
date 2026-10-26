# frozen_string_literal: true

class CreateInvoiceOperations < ActiveRecord::Migration[8.1]
  def change
    create_invoice_operations
    link_reservations_to_their_operation
    record_service_actors_on_audit_events
    create_service_idempotency_receipts
  end

  private

    # The terminal record of each prepare, commit or abort
    # (docs/architecture/timekeeping-soa.md section 7.2). actor_name is the
    # calling service: two services of one company may each use the same
    # operation id without matching each other.
    def create_invoice_operations
      create_table :invoice_operations do |t|
        t.bigint :company_id, null: false
        t.bigint :invoice_id, null: false
        t.uuid :operation_id, null: false
        t.string :actor_name, null: false
        t.string :state, null: false
        t.bigint :desired_entry_ids, array: true, null: false, default: []
        t.string :disposition, null: false
        t.bigint :generation, null: false
        t.datetime :created_at, null: false
        t.datetime :finished_at

        t.index %i[company_id actor_name operation_id], unique: true,
          name: "index_invoice_operations_on_operation_key"
        # At most one unresolved operation per invoice.
        t.index %i[company_id invoice_id], unique: true, where: "state = 'prepared'",
          name: "index_invoice_operations_one_prepared_per_invoice"
        # The target of the reservations foreign key below.
        t.index %i[company_id id operation_id], unique: true,
          name: "index_invoice_operations_on_owner_key"
        t.check_constraint "state IN ('prepared', 'committed', 'aborted')", name: "invoice_operations_state_check"
        t.check_constraint "disposition IN ('active', 'retained')", name: "invoice_operations_disposition_check"
      end
    end

    # invoice_operation_id stays NULL on rows no operation wrote, such as test
    # fixtures or rows copied at cutover; those keep operation_id alone. When it
    # is set, the composite key forces company_id and operation_id to match the
    # owning operation's, so a reservation can never claim another operation's id.
    # PostgreSQL skips the key check while any of its columns is NULL.
    def link_reservations_to_their_operation
      add_column :reservations, :invoice_operation_id, :bigint
      add_index :reservations, %i[company_id invoice_operation_id]
      add_foreign_key :reservations, :invoice_operations,
        column: %i[company_id invoice_operation_id operation_id],
        primary_key: %i[company_id id operation_id],
        name: "fk_reservations_owning_operation"
    end

    # A service has a name and no numeric id, so a service row carries
    # actor_name and a user row carries actor_id. Every existing row is a user
    # row with actor_id set, so the check holds for them.
    def record_service_actors_on_audit_events
      add_column :audit_events, :actor_name, :string
      change_column_null :audit_events, :actor_id, true
      add_check_constraint :audit_events,
        "(actor_type = 'service' AND actor_name IS NOT NULL) OR (actor_type <> 'service' AND actor_id IS NOT NULL)",
        name: "audit_events_actor_check"
    end

    # Stored 2xx answers of service commands, kept apart from the user receipts
    # in idempotency_receipts so that table's key stays five NOT NULL columns.
    # Every key column here is NOT NULL for the same reason: PostgreSQL treats
    # NULLs as distinct in a unique index.
    def create_service_idempotency_receipts
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
