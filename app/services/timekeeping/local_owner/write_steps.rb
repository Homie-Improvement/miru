# frozen_string_literal: true

require "digest"

module Timekeeping
  class LocalOwner
    # The steps every local writer takes inside its own transaction: advisory
    # locks, the generation fence, the reservation-flag read, outbox snapshots
    # and the receipt body round trip. Each writer decides what changes; these
    # steps record it the same way for all of them, so an entry write and a
    # reservation change publish alike.
    module WriteSteps
      KEY_SEPARATOR = "\u001F"
      # The one key every writer of entry_outbox_items takes just before its
      # inserts and holds until commit, so outbox positions commit in the order
      # they were drawn and the relay never passes a position still uncommitted.
      OUTBOX_LOCK_KEY = 2_026_034_001
      # The largest value a PostgreSQL bigint column holds, so a larger id is a
      # bad request rather than a failure inside the write.
      MAX_ID = (2**63) - 1

      module_function

      # An id a bigint column can hold, sent as an Integer.
      def id?(value)
        value.is_a?(Integer) && value.between?(1, MAX_ID)
      end

      # True when the body holds the service token this owner holds, or a user
      # or service token signed with the key it signs user tokens with, so no
      # row or receipt can carry a credential.
      def credential_in_body?(body)
        TimekeepingRules::CredentialScan.found?(
          body,
          held_token: ENV.fetch(Internal::V1::BaseController::SERVICE_TOKEN_ENV, nil),
          public_key: token_public_key
        )
      end

      # The public half of the key the monolith signs user tokens with. An
      # unset or unreadable key is not held, so it matches nothing.
      def token_public_key
        UserToken.private_key_from_env.public_key
      rescue UserToken::MissingKeyError
        nil
      end

      # Takes a transaction-scoped advisory lock on two signed 32-bit keys from
      # a digest of parts, so only writers naming the same parts wait on each
      # other. Rows are always read by their columns, never by this digest.
      def lock_key(*parts)
        advisory_lock(*Digest::SHA256.digest(parts.join(KEY_SEPARATOR)).unpack("l>l>"))
      end

      # The one generation the local owner admits, read FOR SHARE so a handoff
      # that updates the row waits for this write to commit. nil while the
      # monolith is not the prepared owner, during a handoff, or when the row
      # is missing.
      def admitted_generation
        ownership = TimekeepingOwnership.lock("FOR SHARE").find_by(id: TimekeepingOwnership::SINGLETON_ID)
        return if ownership.nil? || !ownership.handoff_step.nil? || EntryOwner.for(ownership) != :prepared

        ownership.generation
      end

      # nil matches nothing, and a sent value that is not a plain integer
      # never matches, so neither a missing generation nor "abc" can be admitted.
      def generation_matches?(sent, stored_generation)
        !stored_generation.nil? && ID.match?(sent.to_s) && Integer(sent.to_s, 10) == stored_generation
      end

      # The company's entries with these ids as stored now, discarded ones
      # included, each with the reservation flag, keyed by id.
      def reserved_rows(company_id, entry_ids)
        LocalEntry.with_reserved.where(company_id:, id: entry_ids).index_by(&:id)
      end

      # One outbox snapshot per row, each read with the reservation flag.
      def write_outbox(company_id:, rows:, generation:)
        return if rows.empty?

        advisory_lock(OUTBOX_LOCK_KEY)
        now = Time.current
        LocalOutboxEntry.insert_all!(rows.map do |row|
          { company_id:, entry_id: row.id, generation:, payload: snapshot(row), created_at: now }
        end)
      end

      # The contract snapshot of one entry, read with the reservation flag:
      # locked is that flag, never the stored entries.locked column.
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

      # Receipt bodies are stored as text, so an answer is written as JSON and
      # parsed back on replay; a replay then answers the same Hash, never the
      # stored string.
      def receipt_body(body)
        JSON.generate(body)
      end

      def replayed_body(stored)
        JSON.parse(stored)
      end

      def advisory_lock(*keys)
        placeholders = Array.new(keys.size, "?").join(", ")
        ApplicationRecord.connection.execute(
          ApplicationRecord.sanitize_sql_array(["SELECT pg_advisory_xact_lock(#{placeholders})", *keys])
        )
      end
      private_class_method :advisory_lock, :token_public_key
    end
  end
end
