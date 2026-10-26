# frozen_string_literal: true

# One place that builds handoff checkpoint rows and correction snapshots, so a
# change to the checkpoint shape edits this builder rather than a row literal
# in every handoff spec.
#
# Columns come from Timekeeping::Handoff::Checkpoint::TABLES and
# Timekeeping::Handoff::CorrectionSnapshots::SNAPSHOT_FIELDS. A column added
# there with no value below raises KeyError here, so the builder cannot fall
# out of step with the shape it builds.
module HandoffRows
  # The checkpoint file the monolith's store writes, loaded by round-trip specs.
  HANDOFF_MONOLITH_CHECKPOINT_PATH = File.expand_path(
    "../../../spec/fixtures/files/timekeeping_handoff/monolith_checkpoint.json", __dir__
  )

  # One row per checkpoint table for one company, linked by id: the
  # reservation, operation, audit and receipt all point at entry `id`.
  # overrides: { table => { column => value } } replaces default values; a
  # column outside the table's shape raises, so a typo cannot pass silently.
  def handoff_checkpoint_tables(company_id:, id:, overrides: {})
    defaults = handoff_row_defaults(company_id:, id:)
    Timekeeping::Handoff::Checkpoint::TABLES.to_h do |table, columns|
      values = defaults.fetch(table).merge(overrides.fetch(table, {}))
      unknown = values.keys - columns
      raise ArgumentError, "#{table}: no such checkpoint columns: #{unknown.join(', ')}" if unknown.any?

      [table, [columns.index_with { |column| values.fetch(column) }]]
    end
  end

  # Joins several companies' tables into one checkpoint's tables.
  def merge_handoff_checkpoint_tables(*tables_list)
    Timekeeping::Handoff::Checkpoint::TABLES.keys.index_with do |table|
      tables_list.flat_map { |tables| tables.fetch(table) }
    end
  end

  # The correction snapshot the monolith sends for a stored entry, in its JSON
  # form, as the correction_snapshots route receives it.
  def handoff_correction_snapshot(entry, locked:)
    entry.attributes.slice(*Timekeeping::Handoff::CorrectionSnapshots::SNAPSHOT_FIELDS)
      .merge("locked" => locked).as_json
  end

  def handoff_monolith_checkpoint_json
    File.read(HANDOFF_MONOLITH_CHECKPOINT_PATH)
  end

  private

    def handoff_row_defaults(company_id:, id:)
      at = Time.utc(2026, 3, 2, 9)
      operation_id = SecureRandom.uuid
      {
        "entries" => {
          "id" => id, "company_id" => company_id, "version" => 2, "project_id" => 10, "user_id" => 20,
          "agent_id" => nil, "work_date" => Date.new(2026, 3, 2), "duration" => 60.0, "note" => "",
          "bill_status" => "unbilled", "review_status" => "not_required", "locked" => true, "source" => "manual",
          "source_metadata" => {}, "external_run_id" => nil, "external_session_id" => nil, "proof_url" => nil,
          "proof_metadata" => {}, "discarded_at" => nil, "created_at" => at, "updated_at" => at
        },
        "reservations" => {
          "company_id" => company_id, "entry_id" => id, "invoice_id" => 5, "state" => "committed",
          "disposition" => "active", "operation_id" => operation_id, "created_at" => at, "invoice_operation_id" => id
        },
        "invoice_operations" => {
          "id" => id, "company_id" => company_id, "invoice_id" => 5, "operation_id" => operation_id,
          "actor_name" => "invoice-service", "state" => "committed", "desired_entry_ids" => [id],
          "disposition" => "active", "generation" => 1, "created_at" => at, "finished_at" => at
        },
        "entry_audits" => {
          "id" => id, "company_id" => company_id, "entry_id" => id, "actor_type" => "user", "actor_id" => 20,
          "actor_name" => nil, "action" => "create", "before" => Timekeeping::Handoff::Checkpoint::JSON_NULL,
          "after" => { "duration" => 60 }, "entry_created_at" => at, "created_at" => at
        },
        "idempotency_records" => {
          "id" => id, "company_id" => company_id, "actor_type" => "user", "actor_id" => 20, "operation" => "create",
          "key" => "key-#{id}", "fingerprint" => "fp-#{id}", "status" => 201, "body" => "{}", "created_at" => at
        },
        "service_idempotency_receipts" => {
          "id" => id, "company_id" => company_id, "actor_name" => "invoice-service", "operation" => "commit",
          "key" => operation_id, "fingerprint" => "fp-#{id}", "status" => 200,
          "body" => '{"reserved":1,"released":0}', "created_at" => at
        }
      }
    end
end

# Reads the stored state a handoff call can change, so every spec that proves a
# refused call changed nothing compares the same tables in the same way.
module HandoffStoredState
  # Every table a handoff load or correction can write.
  HANDOFF_STORED_TABLES = %w[entries reservations invoice_operations audit_events idempotency_receipts
                             service_idempotency_receipts outbox_snapshots].freeze

  # Every row of every stored table, read as Postgres returns it, so a change
  # to any value shows up.
  def handoff_stored_rows
    HANDOFF_STORED_TABLES.index_with do |table|
      ApplicationRecord.connection.select_rows("SELECT * FROM #{table} ORDER BY 1, 2")
    end
  end

  # The id the table's sequence hands out next, without consuming it.
  def handoff_next_id(table)
    ApplicationRecord.connection.select_value(
      "SELECT CASE WHEN is_called THEN last_value + 1 ELSE last_value END FROM #{table}_id_seq"
    ).to_i
  end
end

RSpec.configure do |config|
  config.include HandoffRows
  config.include HandoffStoredState
end
