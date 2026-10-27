# frozen_string_literal: true

module Timekeeping
  # Writes entry snapshots to the prepared monolith's outbox
  # (entry_outbox_items), the one place every prepared-store writer builds a
  # snapshot, so a stored entry publishes the same payload whichever writer
  # changed it.
  module EntryOutbox
    # The one key every writer of entry_outbox_items takes just before its
    # inserts and holds until commit, so outbox positions commit in the order
    # they were drawn and the relay never passes a position still uncommitted.
    LOCK_KEY = 2_026_034_001

    module_function

    # rows are LocalEntry records read with LocalEntry.with_reserved, so the
    # snapshot's locked value is the reservation flag, never the stored
    # entries.locked column. Each row's own company_id goes on its outbox row.
    def write(rows, generation:)
      return if rows.empty?

      ApplicationRecord.connection.execute(
        ApplicationRecord.sanitize_sql_array(["SELECT pg_advisory_xact_lock(?)", LOCK_KEY])
      )
      now = Time.current
      LocalOutboxEntry.insert_all!(rows.map do |row|
        { company_id: row.company_id, entry_id: row.id, generation:, payload: snapshot(row), created_at: now }
      end)
    end

    # Maps the id of each row whose snapshot the projection would refuse to
    # the names of its refused fields, checked with the same casts
    # SnapshotBatch applies on the consumer side. The relay delivers in
    # order, so one refused snapshot would hold back every later one. Only
    # field names are returned: a bad stored value can hold anything.
    def invalid_fields(rows)
      rows.to_h { |row| [row.id, refused_fields(snapshot(row))] }.reject { |_id, fields| fields.empty? }
    end

    def refused_fields(payload)
      SnapshotBatch::FIELD_CASTS.filter_map do |field, cast|
        cast.call(payload[field])
        nil
      rescue SnapshotBatch::InvalidValue
        field
      end
    end

    # The contract snapshot of one entry.
    def snapshot(row)
      json_fields(row, SnapshotBatch::ENTRY_FIELDS)
    end

    def json_fields(row, fields)
      fields.index_with { |field| json_value(field == "locked" ? row.reserved : row[field]) }
    end

    # Times as UTC with microseconds, the precision the column stores, and
    # dates as ISO 8601; every other value, a Float duration included, as is.
    def json_value(value)
      case value
      when Time, ActiveSupport::TimeWithZone then value.utc.iso8601(6)
      when Date then value.iso8601
      else value
      end
    end
  end
end
