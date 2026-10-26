# frozen_string_literal: true

# Gives the prepared entry_audits and idempotency_records tables the columns,
# types and nullability of Timekeeping's audit_events and idempotency_receipts
# (timekeeping/db/migrate/20260201000000_create_write_tables.rb), so a
# checkpoint carries their rows between the two applications without losing a
# value. The old columns cannot hold Timekeeping's before/after audit values or
# the exact replayed response body, so both directions refuse to run over rows
# instead of converting them.
#
# entry_audits keeps its composite foreign key to entries, which audit_events
# does not have: it is not a column, and it stops an audit row from pointing at
# another company's entry.
class MatchPreparedTablesToTimekeeping < ActiveRecord::Migration[8.1]
  class TableNotEmptyError < StandardError; end

  TABLES = %w[entry_audits idempotency_records].freeze

  def up
    refuse_unless_empty!

    safety_assured do
      remove_column :entry_audits, :changed_fields, :jsonb, null: false, default: {}
      change_column :entry_audits, :actor_id, :bigint, null: false, using: "actor_id::bigint"
      add_column :entry_audits, :before, :jsonb
      add_column :entry_audits, :after, :jsonb, null: false
      add_column :entry_audits, :entry_created_at, :datetime, null: false

      remove_index :idempotency_records, :expires_at
      remove_column :idempotency_records, :expires_at, :datetime, null: false
      remove_column :idempotency_records, :request_digest, :string, null: false
      remove_column :idempotency_records, :response_status, :integer, null: false
      remove_column :idempotency_records, :response_body, :jsonb, null: false, default: {}
      change_column :idempotency_records, :actor_id, :bigint, null: false, using: "actor_id::bigint"
      add_column :idempotency_records, :fingerprint, :string, null: false
      add_column :idempotency_records, :status, :integer, null: false
      add_column :idempotency_records, :body, :text, null: false
    end
  end

  def down
    refuse_unless_empty!

    safety_assured do
      remove_column :entry_audits, :entry_created_at
      remove_column :entry_audits, :after
      remove_column :entry_audits, :before
      change_column :entry_audits, :actor_id, :string, null: true
      add_column :entry_audits, :changed_fields, :jsonb, null: false, default: {}

      remove_column :idempotency_records, :body
      remove_column :idempotency_records, :status
      remove_column :idempotency_records, :fingerprint
      change_column :idempotency_records, :actor_id, :string, null: false
      add_column :idempotency_records, :request_digest, :string, null: false
      add_column :idempotency_records, :response_status, :integer, null: false
      add_column :idempotency_records, :response_body, :jsonb, null: false, default: {}
      add_column :idempotency_records, :expires_at, :datetime, null: false
      add_index :idempotency_records, :expires_at
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
