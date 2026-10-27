# frozen_string_literal: true

require "digest"

module Timekeeping
  # The steps every writer takes inside its own transaction: advisory locks,
  # the generation check, audit rows and outbox snapshots. Each
  # writer decides what changes; these steps record the change the same way
  # for all of them, so an entry write and a reservation change publish alike.
  module WriteSteps
    KEY_SEPARATOR = "\u001F"
    # The one key every writer takes just before its outbox inserts and holds
    # until commit, so outbox positions commit in the order they were drawn.
    OUTBOX_LOCK_KEY = 2_026_034_001
    UNPUBLISHABLE_REASON = :unpublishable_entry

    # Raised by write_outbox when a stored row breaks a SnapshotValues rule.
    # entries maps each such entry id to its failing field names. The message
    # and the answer name fields only, never a stored value, so nothing a row
    # holds leaves in a response or a log line.
    class UnpublishableRows < StandardError
      attr_reader :entries

      def initialize(entries)
        @entries = entries
        super("stored entries hold values a snapshot may not carry: " \
              "#{entries.map { |id, fields| "entry #{id} (#{fields.join(', ')})" }.join('; ')}")
      end

      # The refusal a writer answers with once its transaction has rolled back.
      def outcome
        listed = entries.map { |id, fields| { "entry_id" => id, "fields" => fields } }
        WriteOutcome.success(Reasons.status(UNPUBLISHABLE_REASON),
                             "reason" => UNPUBLISHABLE_REASON.to_s, "entries" => listed)
      end
    end

    module_function

    # Takes a transaction-scoped advisory lock on two signed 32-bit keys from
    # a digest of parts, so only writers naming the same parts wait on each
    # other. Rows are always read by their columns, never by this digest.
    def lock_key(*parts)
      high, low = Digest::SHA256.digest(parts.join(KEY_SEPARATOR)).unpack("l>l>")
      connection.execute(ApplicationRecord.sanitize_sql_array(["SELECT pg_advisory_xact_lock(?, ?)", high, low]))
    end

    # A missing generation, or one that is not a plain integer, is never current.
    def generation_matches?(sent, generation)
      EntryCommand::ID.match?(sent.to_s) && Integer(sent.to_s, 10) == generation
    end

    # The company's entries with these ids as stored now, discarded ones
    # included, each with the reservation flag, keyed by id.
    def reserved_rows(company_id, entry_ids)
      Entry.where(company_id:, id: entry_ids).select("entries.*", EntriesQuery::RESERVED).index_by(&:id)
    end

    # One audit row per event. actor holds the actor columns: actor_type with
    # actor_id for a user, or actor_name for a service. Each event holds
    # entry_id, before, after and entry_created_at.
    def write_audit(company_id:, actor:, action:, events:)
      now = Time.current
      events.each do |event|
        AuditEvent.create!(company_id:, action:, created_at: now, **actor, **event)
      end
    end

    # One outbox snapshot per row, each read with EntriesQuery::RESERVED.
    # Stored rows can hold values that never passed SnapshotValues, such as
    # ones a checkpoint load copied in, and the projection would refuse such
    # a snapshot and hold back every later delivery. So every row is checked
    # first, and one bad row raises UnpublishableRows with nothing inserted;
    # the caller's transaction then rolls the whole write back.
    def write_outbox(rows, generation)
      return if rows.empty?

      snapshots = rows.map { |row| OutboxFields.row(row, generation:) }
      invalid = SnapshotValues.invalid_snapshots(snapshots)
      raise UnpublishableRows, invalid if invalid.any?

      connection.execute(ApplicationRecord.sanitize_sql_array(["SELECT pg_advisory_xact_lock(?)", OUTBOX_LOCK_KEY]))
      OutboxSnapshot.insert_all!(snapshots)
    end

    def connection
      ApplicationRecord.connection
    end
    private_class_method :connection
  end
end
