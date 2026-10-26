# frozen_string_literal: true

class CreateInvoiceOperations < ActiveRecord::Migration[8.1]
  def change
    # The terminal record of each invoice prepare, commit or abort
    # (docs/architecture/timekeeping-soa.md section 7.2). The columns, index
    # and checks equal the monolith's invoice_operations table, so a handoff
    # checkpoint's operation receipts load into either application;
    # spec/db/invoice_operations_schema_spec.rb compares the two schemas.
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
end
