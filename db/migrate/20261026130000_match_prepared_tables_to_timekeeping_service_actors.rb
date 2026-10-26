# frozen_string_literal: true

# Keeps entry_audits and reservations equal to Timekeeping's audit_events and
# reservations after
# timekeeping/db/migrate/20260601000000_create_invoice_operations.rb, so a
# checkpoint still carries every column between the two applications:
#
# - entry_audits gets actor_name and a nullable actor_id, because a service
#   has a name and no numeric id. The check constraint is Timekeeping's.
# - reservations gets invoice_operation_id, the operation that wrote the row.
#
# reservations gets no foreign key to invoice_operations here: a checkpoint
# load inserts reservations before invoice_operations.
#
# Rolling back would drop the service actors of stored audit rows, so both
# directions refuse to run over rows.
class MatchPreparedTablesToTimekeepingServiceActors < ActiveRecord::Migration[8.1]
  class TableNotEmptyError < StandardError; end

  TABLES = %w[entry_audits reservations].freeze

  def up
    refuse_unless_empty!

    safety_assured do
      add_column :entry_audits, :actor_name, :string
      change_column_null :entry_audits, :actor_id, true
      add_check_constraint :entry_audits,
        "(actor_type = 'service' AND actor_name IS NOT NULL) OR (actor_type <> 'service' AND actor_id IS NOT NULL)",
        name: "entry_audits_actor_check"

      add_column :reservations, :invoice_operation_id, :bigint
    end
  end

  def down
    refuse_unless_empty!

    safety_assured do
      remove_column :reservations, :invoice_operation_id

      remove_check_constraint :entry_audits, name: "entry_audits_actor_check"
      change_column_null :entry_audits, :actor_id, false
      remove_column :entry_audits, :actor_name
    end
  end

  private

    # The lock is held until the migration's transaction commits, so no row can
    # arrive between this check and the column changes.
    def refuse_unless_empty!
      safety_assured { execute "LOCK TABLE #{TABLES.join(', ')} IN ACCESS EXCLUSIVE MODE" }

      occupied = TABLES.select { |table| select_value("SELECT 1 FROM #{table} LIMIT 1") }
      return if occupied.empty?

      raise TableNotEmptyError,
        "Refusing to reshape tables that hold rows: #{occupied.join(', ')}. Their values have no column to move to."
    end
end
