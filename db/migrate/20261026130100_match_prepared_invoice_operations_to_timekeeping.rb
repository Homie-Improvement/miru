# frozen_string_literal: true

# Keeps the prepared invoice_operations table equal to Timekeeping's after
# timekeeping/db/migrate/20260601000000_create_invoice_operations.rb, so a
# checkpoint still carries every operation receipt column between the two
# applications: actor_name, the service that ran the operation, with
# Timekeeping's two unique keys over it and over the operation's identity.
#
# The column is NOT NULL, as in Timekeeping, so both directions refuse to run
# over rows: an existing row has no actor to fill it with, and rolling back
# would drop the actor of a stored receipt.
class MatchPreparedInvoiceOperationsToTimekeeping < ActiveRecord::Migration[8.1]
  class TableNotEmptyError < StandardError; end

  def up
    refuse_unless_empty!

    safety_assured do
      add_column :invoice_operations, :actor_name, :string, null: false
      add_index :invoice_operations, %i[company_id actor_name operation_id], unique: true,
        name: "index_invoice_operations_on_operation_key"
      add_index :invoice_operations, %i[company_id id operation_id], unique: true,
        name: "index_invoice_operations_on_owner_key"
    end
  end

  def down
    refuse_unless_empty!

    safety_assured do
      remove_index :invoice_operations, name: "index_invoice_operations_on_owner_key"
      remove_index :invoice_operations, name: "index_invoice_operations_on_operation_key"
      remove_column :invoice_operations, :actor_name
    end
  end

  private

    # The lock is held until the migration's transaction commits, so no row can
    # arrive between this check and the column change.
    def refuse_unless_empty!
      safety_assured { execute "LOCK TABLE invoice_operations IN ACCESS EXCLUSIVE MODE" }
      return unless select_value("SELECT 1 FROM invoice_operations LIMIT 1")

      raise TableNotEmptyError,
        "Refusing to reshape invoice_operations while it holds rows: their actor_name has no value to take."
    end
end
