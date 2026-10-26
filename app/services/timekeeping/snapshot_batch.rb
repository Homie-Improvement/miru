# frozen_string_literal: true

require "yaml"

module Timekeeping
  # Reads one entry snapshot batch (contracts/timekeeping/entry_snapshots.yml)
  # into rows ready for timesheet_entries. It is pure: it reads no database
  # state. The projection writes rows without model callbacks, so this is the
  # only check on what a snapshot may write; every key list is exact, and a
  # value of the wrong type or outside an enum makes the whole batch invalid.
  module SnapshotBatch
    CONTRACT = YAML.safe_load_file(Rails.root.join("contracts/timekeeping/entry_snapshots.yml")).freeze
    SCHEMA_VERSION = CONTRACT.fetch("schema_version")
    BATCH_FIELDS = CONTRACT.fetch("batch_fields").freeze
    ITEM_FIELDS = CONTRACT.fetch("item_fields").freeze
    ENTRY_FIELDS = CONTRACT.fetch("entry_fields").freeze

    # One accepted snapshot. row holds the timesheet_entries column values, with
    # enums as their stored integers, JSON columns as JSON text and times as
    # UTC text, so the writer can quote each value as it is.
    Item = Data.define(:generation, :outbox_position, :row) do
      def entry_id = row.fetch("id")
      def company_id = row.fetch("company_id")
      def project_id = row.fetch("project_id")
    end

    class InvalidValue < StandardError; end

    id = ->(value) { value.is_a?(Integer) && value.positive? ? value : raise(InvalidValue) }
    optional = ->(cast) { ->(value) { value.nil? ? nil : cast.call(value) } }
    text = ->(value) { value.is_a?(String) ? value : raise(InvalidValue) }
    json_object = ->(value) { value.is_a?(Hash) ? value.to_json : raise(InvalidValue) }
    # timesheet_entries stores times without a zone, as UTC, so an offset in
    # the snapshot is converted here rather than dropped by PostgreSQL.
    time = lambda do |value|
      Time.iso8601(text.call(value)).utc.strftime("%Y-%m-%d %H:%M:%S.%6N")
    rescue ArgumentError
      raise InvalidValue
    end
    date = lambda do |value|
      Date.iso8601(text.call(value)).iso8601
    rescue Date::Error
      raise InvalidValue
    end
    enum = ->(mapping) { ->(value) { mapping.fetch(value) { raise InvalidValue } } }

    # How each contract entry field becomes its column value.
    FIELD_CASTS = {
      "id" => id,
      "project_id" => id,
      "user_id" => id,
      "agent_id" => optional.call(id),
      "work_date" => date,
      "duration" => ->(value) { value.is_a?(Numeric) && !value.negative? ? value.to_f : raise(InvalidValue) },
      "note" => optional.call(text),
      "bill_status" => enum.call(TimesheetEntry.bill_statuses),
      "review_status" => enum.call(TimesheetEntry.review_statuses),
      "locked" => ->(value) { [true, false].include?(value) ? value : raise(InvalidValue) },
      "source" => ->(value) { TimesheetEntry::SOURCES.include?(value) ? value : raise(InvalidValue) },
      "source_metadata" => json_object,
      "external_run_id" => optional.call(text),
      "external_session_id" => optional.call(text),
      "proof_url" => optional.call(text),
      "proof_metadata" => json_object,
      "discarded_at" => optional.call(time),
      "created_at" => time,
      "updated_at" => time,
      "company_id" => id,
      "version" => id
    }.freeze

    unless FIELD_CASTS.keys.sort == ENTRY_FIELDS.sort
      raise "Timekeeping::SnapshotBatch::FIELD_CASTS must name exactly the contract's entry_fields"
    end

    module_function

    # Returns the batch's items in outbox_position order, or nil when any part
    # of the batch breaks the contract.
    def parse(batch)
      return nil unless exact_keys?(batch, BATCH_FIELDS) && batch["schema_version"] == SCHEMA_VERSION
      return nil unless batch["snapshots"].is_a?(Array)

      batch["snapshots"].map { |item| parse_item(item) }.sort_by(&:outbox_position)
    rescue InvalidValue
      nil
    end

    def parse_item(item)
      raise InvalidValue unless exact_keys?(item, ITEM_FIELDS) && exact_keys?(item["entry"], ENTRY_FIELDS)

      Item.new(
        generation: id_value(item["generation"]),
        outbox_position: id_value(item["outbox_position"]),
        row: FIELD_CASTS.to_h { |field, cast| [field, cast.call(item["entry"][field])] }
      )
    end

    def id_value(value)
      FIELD_CASTS.fetch("id").call(value)
    end

    def exact_keys?(value, fields)
      value.is_a?(Hash) && value.keys.sort == fields.sort
    end
    private_class_method :parse_item, :id_value, :exact_keys?
  end
end
