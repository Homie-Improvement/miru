# frozen_string_literal: true

# The monolith's reservation ledger (docs/architecture/timekeeping-soa.md
# sections 7.2 and 9). It lets an intent store the whole reservation request,
# and adds the record of what each invoice holds and the commit and abort
# messages waiting for delivery. Schema only: nothing writes these columns or
# tables yet, so there is nothing to fill.
class AddInvoiceReservationLedger < ActiveRecord::Migration[8.1]
  DISPOSITIONS = %w[active retained].freeze
  OUTBOX_KINDS = %w[commit abort].freeze

  def change
    add_intent_request_columns
    create_invoice_entry_holdings
    create_invoice_operation_outbox_items
  end

  private

    # A retry or recovery resends the stored request and never recomputes it,
    # so both columns are NOT NULL. The defaults keep a row written without
    # them a valid request: no entries, active.
    def add_intent_request_columns
      add_column :invoice_operation_intents, :desired_entry_ids, :bigint, array: true, null: false, default: []
      add_column :invoice_operation_intents, :disposition, :string, null: false, default: "active"

      # Nothing writes invoice_operation_intents yet, so validating the
      # constraint scans an empty table and holds its lock only briefly.
      safety_assured do
        add_check_constraint :invoice_operation_intents, "disposition IN (#{quoted_list(DISPOSITIONS)})",
          name: "invoice_operation_intents_disposition_check"
      end
    end

    # What each invoice holds. invoice_id has no foreign key, so a holding
    # outlives a destroyed invoice and its entries stay accounted for.
    def create_invoice_entry_holdings
      create_table :invoice_entry_holdings do |t|
        t.bigint :company_id, null: false
        t.bigint :invoice_id, null: false
        t.bigint :entry_ids, array: true, null: false, default: []
        t.string :disposition, null: false, default: "active"
        t.datetime :updated_at, null: false

        t.index %i[company_id invoice_id], unique: true,
          name: "index_invoice_entry_holdings_on_company_invoice"
        t.check_constraint "disposition IN (#{quoted_list(DISPOSITIONS)})", name: "invoice_entry_holdings_disposition_check"
      end
    end

    # Commit and abort messages waiting for delivery. The unique index carries
    # the company, so one company's operation id never blocks another's, and a
    # retried write never adds a second message of the same kind.
    def create_invoice_operation_outbox_items
      create_table :invoice_operation_outbox_items do |t|
        t.bigint :company_id, null: false
        t.bigint :invoice_id
        t.uuid :operation_id, null: false
        t.string :kind, null: false
        t.jsonb :payload, null: false
        t.integer :attempts, null: false, default: 0
        t.datetime :delivered_at
        t.datetime :created_at, null: false

        t.index %i[company_id operation_id kind], unique: true,
          name: "index_invoice_operation_outbox_items_on_company_operation_kind"
        t.check_constraint "kind IN (#{quoted_list(OUTBOX_KINDS)})", name: "invoice_operation_outbox_items_kind_check"
      end
    end

    def quoted_list(values)
      values.map { |value| connection.quote(value) }.join(", ")
    end
end
