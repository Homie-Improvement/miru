# frozen_string_literal: true

# Lets idempotency_records hold receipts for service callers, which have a
# name and no numeric user id. The check constraint matches
# entry_audits_actor_check: a service row needs actor_name, any other row
# needs actor_id.
#
# index_idempotency_records_on_scope_and_key keeps user receipts unique, but a
# service row has a NULL actor_id and never conflicts on it, so service
# receipts get a unique index of their own.
#
# Rolling back would drop the actor names of stored service receipts, so both
# directions refuse to run over rows.
class AddServiceActorsToIdempotencyRecords < ActiveRecord::Migration[8.1]
  class TableNotEmptyError < StandardError; end

  TABLES = %w[idempotency_records].freeze
  SERVICE_INDEX = "index_idempotency_records_on_service_scope_and_key"

  def up
    refuse_unless_empty!

    safety_assured do
      add_column :idempotency_records, :actor_name, :string
      change_column_null :idempotency_records, :actor_id, true
      add_check_constraint :idempotency_records,
        "(actor_type = 'service' AND actor_name IS NOT NULL) OR (actor_type <> 'service' AND actor_id IS NOT NULL)",
        name: "idempotency_records_actor_check"
      add_index :idempotency_records, %i[company_id actor_type actor_name operation key],
        unique: true, where: "actor_type = 'service'", name: SERVICE_INDEX
    end
  end

  def down
    refuse_unless_empty!

    safety_assured do
      remove_index :idempotency_records, name: SERVICE_INDEX
      remove_check_constraint :idempotency_records, name: "idempotency_records_actor_check"
      change_column_null :idempotency_records, :actor_id, false
      remove_column :idempotency_records, :actor_name
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
