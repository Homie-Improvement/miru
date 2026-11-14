# frozen_string_literal: true

require "digest"

module Timekeeping
  class LocalOwner
    # The steps every local writer takes inside its own transaction: the
    # generation fence, advisory locks, audit rows and outbox snapshots. Each
    # writer decides what changes; these steps record the change the same way
    # for all of them, so an entry write and a reservation change publish alike.
    module WriteSteps
      ID = TimekeepingRules::EntryDecision::ID
      UNPUBLISHABLE_REASON = :unpublishable_entry
      SHARED_OWNERSHIP_LOCK = "FOR SHARE"
      # The ownership read of a service writer; see locked_generation_nowait
      # for why it never waits.
      NOWAIT_OWNERSHIP_LOCK = "FOR SHARE NOWAIT"

      # Raised when the NOWAIT ownership read finds the row locked, so only
      # that read, and no other lock wait, is answered as stale_generation.
      class OwnershipQueued < StandardError; end

      # What a write answers: an HTTP status and a JSON-ready body with string
      # keys. A replayed receipt answers the body parsed from the stored text,
      # so every body is built to survive that round trip unchanged.
      Outcome = Data.define(:status, :body) do
        def self.refusal(reason)
          new(status: LocalOwner::STATUS.fetch(reason), body: { "reason" => reason.to_s })
        end

        def self.success(status, payload)
          new(status:, body: JSON.parse(JSON.generate(payload)))
        end
      end

      # Raised by record_flips when a flipped entry's stored row holds a value
      # the projection would refuse. entries maps each such entry id to its
      # refused field names; neither the message nor the answer carries a
      # stored value. Raised inside the writer's savepoint, so every row the
      # write made rolls back before the caller answers with outcome.
      class UnpublishableRows < StandardError
        attr_reader :entries

        def initialize(entries)
          @entries = entries
          super("stored entries hold values a snapshot may not carry: " \
                "#{entries.map { |id, fields| "entry #{id} (#{fields.join(', ')})" }.join('; ')}")
        end

        def outcome
          listed = entries.map { |id, fields| { "entry_id" => id, "fields" => fields } }
          Outcome.success(LocalOwner::STATUS.fetch(UNPUBLISHABLE_REASON),
                          "reason" => UNPUBLISHABLE_REASON.to_s, "entries" => listed)
        end
      end

      module_function

      # The one generation the local owner admits, read with lock so a handoff
      # that updates the row waits for this write to commit. nil while the
      # monolith is not the prepared owner, during a handoff, or when the row
      # is missing.
      def admitted_generation(lock: SHARED_OWNERSHIP_LOCK)
        ownership = TimekeepingOwnership.lock(lock).find_by(id: TimekeepingOwnership::SINGLETON_ID)
        return if ownership.nil? || !ownership.handoff_step.nil? || EntryOwner.for(ownership) != :prepared

        ownership.generation
      end

      # The admitted generation, read FOR SHARE NOWAIT. A billing write holds
      # the ownership row FOR SHARE before it takes the invoice lock, so with
      # a handoff's update queued on that row a waiting read here could close
      # a lock cycle. Raises OwnershipQueued instead of waiting, which the
      # writer answers as stale_generation.
      def locked_generation_nowait
        stored_generation = admitted_generation(lock: NOWAIT_OWNERSHIP_LOCK)
        raise OwnershipQueued, "an ownership update is waiting on the row" if ownership_update_queued?

        stored_generation
      rescue ActiveRecord::LockWaitTimeout => error
        raise OwnershipQueued, error.message
      end

      # PostgreSQL grants a FOR SHARE request beside other share holders
      # even while an update waits for them, so NOWAIT alone does not see a
      # queued handoff. A backend waiting to lock a row holds a lock on that
      # tuple for as long as it waits, so any tuple lock another backend
      # holds on the ownership table means an update is queued there.
      def ownership_update_queued?
        ApplicationRecord.connection.select_value(ApplicationRecord.sanitize_sql_array([<<~SQL.squish, TimekeepingOwnership.table_name]))
          SELECT EXISTS (
            SELECT 1 FROM pg_locks
            WHERE locktype = 'tuple' AND relation = to_regclass(?) AND pid <> pg_backend_pid()
          )
        SQL
      end

      # nil matches nothing, and a sent value that is not a plain integer
      # never matches, so neither a missing header nor "abc" can be admitted.
      def generation_matches?(sent, stored_generation)
        !stored_generation.nil? && ID.match?(sent.to_s) && Integer(sent.to_s, 10) == stored_generation
      end

      # A transaction-scoped advisory lock, so a rollback at any step releases it.
      def advisory_lock(*keys)
        placeholders = Array.new(keys.size, "?").join(", ")
        ApplicationRecord.connection.execute(
          ApplicationRecord.sanitize_sql_array(["SELECT pg_advisory_xact_lock(#{placeholders})", *keys])
        )
      end

      # Only writers naming the same parts wait on each other. The lock is
      # taken on two signed 32-bit keys from a digest of the parts; rows are
      # always read by their columns, never by this key.
      def lock_key(*parts)
        advisory_lock(*Digest::SHA256.digest(parts.join(LocalOwner::KEY_SEPARATOR)).unpack("l>l>"))
      end

      # One audit row per event. actor holds the actor columns: actor_type
      # with actor_id for a user, or actor_name for a service. Each event
      # holds entry_id, before, after and entry_created_at.
      def write_audit(company_id:, actor:, action:, events:)
        now = Time.current
        events.each { |event| AuditRow.create!(company_id:, action:, created_at: now, **actor, **event) }
      end

      # Rows are read with the reservation flag, so each snapshot's locked is
      # that flag, never the stored entries.locked column.
      def write_outbox(rows, generation)
        EntryOutbox.write(rows, generation:)
      end

      # entries are the company's rows read with their reservation flag once
      # their row locks were held, before the reservation change. Each one
      # whose flag differs now gets version + 1, one audit row and one outbox
      # snapshot; a change that keeps the flag writes none. A flipped row the
      # projection would refuse raises UnpublishableRows before the audit and
      # outbox writes. Returns the flipped entry ids.
      # :reek:LongParameterList
      def record_flips(company_id:, entries:, actor:, action:, generation:, checkpoint:)
        after = reserved_rows(company_id, entries.map(&:id))
        flipped = entries.reject { |entry| after.fetch(entry.id).reserved == entry.reserved }
        return [] if flipped.empty?

        rows = bump_versions(company_id, flipped.map(&:id))
        checkpoint.call(:entry_written)
        invalid = EntryOutbox.invalid_fields(rows)
        raise UnpublishableRows, invalid if invalid.any?

        write_audit(company_id:, actor:, action:, events: flipped.map { |entry| locked_event(entry) })
        checkpoint.call(:audit_written)
        write_outbox(rows, generation)
        checkpoint.call(:outbox_written)
        rows.map(&:id)
      end

      # Writes version + 1 on each entry and returns the rows as stored now,
      # with the reservation flag, in the order of entry_ids.
      def bump_versions(company_id, entry_ids)
        LocalEntry.where(company_id:, id: entry_ids).update_all(["version = version + 1, updated_at = ?", Time.current])
        reserved_rows(company_id, entry_ids).values_at(*entry_ids)
      end

      # The company's entries with these ids as stored now, discarded ones
      # included, each with the reservation flag, keyed by id.
      def reserved_rows(company_id, entry_ids)
        LocalEntry.with_reserved.where(company_id:, id: entry_ids).index_by(&:id)
      end

      def locked_event(entry)
        { entry_id: entry.id, before: { "locked" => entry.reserved }, after: { "locked" => !entry.reserved },
          entry_created_at: entry.created_at }
      end
      private_class_method :locked_event, :ownership_update_queued?
    end
  end
end
