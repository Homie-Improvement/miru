# frozen_string_literal: true

module Timekeeping
  # The values an entry snapshot may carry, field by field. The projection
  # (the monolith's Timekeeping::SnapshotBatch) refuses a whole batch when one
  # snapshot holds a value it cannot store, and the relay delivers in outbox
  # order, so one refused snapshot holds back every later one. EntryCommand,
  # Handoff::CorrectionSnapshots and the checkpoint load (Handoff::ServiceStore,
  # through Handoff::CheckpointEntryValues) check their values against these
  # rules before they write; each rule is at least as strict as the
  # projection's check on the same field. WriteSteps.write_outbox republishes stored rows without them.
  #
  # The lists are written out here because the app deploys without the
  # contracts directory; spec/services/timekeeping/snapshot_values_spec.rb
  # keeps them equal to entry_values in contracts/timekeeping/entry_snapshots.yml.
  module SnapshotValues
    SOURCES = %w[manual cli mcp automation import].freeze
    BILL_STATUSES = %w[non_billable unbilled billed].freeze
    REVIEW_STATUSES = %w[not_required pending_review approved rejected].freeze

    # The deepest metadata object accepted, counting Hashes and Arrays as JSON
    # does. The relay reads stored metadata with JSON's default limit of 100
    # levels, and a snapshot carries metadata four levels down (batch,
    # snapshots list, item, entry), so deeper metadata could be stored but
    # never delivered.
    METADATA_MAX_NESTING = 96
    ISO_DATE = /\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/

    # Whether value nests at most levels Hashes and Arrays deep. The walk stops
    # at the limit, so very deep or cyclic metadata is refused instead of
    # exhausting the stack.
    def self.nested_within?(value, levels)
      children =
        case value
        when Hash then value.values
        when Array then value
        else return true
        end
      levels.positive? && children.all? { |child| nested_within?(child, levels - 1) }
    end
    private_class_method :nested_within?

    id = ->(value) { value.is_a?(Integer) && value.positive? }
    optional = ->(rule) { ->(value) { value.nil? || rule.call(value) } }
    text = ->(value) { value.is_a?(String) }
    one_of = ->(list) { ->(value) { list.include?(value) } }
    metadata = ->(value) { value.is_a?(Hash) && nested_within?(value, METADATA_MAX_NESTING) }
    # In-process callers build snapshots from model attributes, so a Date or
    # Time is accepted beside the ISO text a parsed JSON body holds. Both
    # serialize to the ISO text the projection parses.
    date = lambda do |value|
      return true if value.is_a?(Date)

      value.is_a?(String) && ISO_DATE.match?(value) && Date.iso8601(value).is_a?(Date)
    rescue Date::Error
      false
    end
    time = lambda do |value|
      return true if value.is_a?(Time)

      value.is_a?(String) && Time.iso8601(value).is_a?(Time)
    rescue ArgumentError
      false
    end

    # One rule for every entry field except version, which the producer
    # assigns itself.
    RULES = {
      "id" => id,
      "project_id" => id,
      "user_id" => id,
      "agent_id" => optional.call(id),
      "work_date" => date,
      # JSON has no Infinity or NaN, so the relay could not send such a row.
      "duration" => ->(value) { value.is_a?(Numeric) && value.finite? && !value.negative? },
      "note" => optional.call(text),
      "bill_status" => one_of.call(BILL_STATUSES),
      "review_status" => one_of.call(REVIEW_STATUSES),
      "locked" => ->(value) { [true, false].include?(value) },
      "source" => one_of.call(SOURCES),
      "source_metadata" => metadata,
      "external_run_id" => optional.call(text),
      "external_session_id" => optional.call(text),
      "proof_url" => optional.call(text),
      "proof_metadata" => metadata,
      "discarded_at" => optional.call(time),
      "created_at" => time,
      "updated_at" => time,
      "company_id" => id
    }.freeze

    # The names of the snapshot's fields whose value breaks its rule, in
    # rules order; [] when every value is valid. A caller whose input does not
    # carry every field as a snapshot does passes the subset that applies.
    def self.invalid_fields(snapshot, rules: RULES)
      rules.reject { |field, valid| valid.call(snapshot[field]) }.keys
    end
  end
end
