# frozen_string_literal: true

require "digest"

module Timekeeping
  # The steps every writer takes inside its own transaction: advisory locks,
  # the company's generation check, audit rows and outbox snapshots. Each
  # writer decides what changes; these steps record the change the same way
  # for all of them, so an entry write and a reservation change publish alike.
  module WriteSteps
    KEY_SEPARATOR = "\u001F"
    # The one key every writer takes just before its outbox inserts and holds
    # until commit, so outbox positions commit in the order they were drawn.
    OUTBOX_LOCK_KEY = 2_026_034_001

    module_function

    # Takes a transaction-scoped advisory lock on two signed 32-bit keys from
    # a digest of parts, so only writers naming the same parts wait on each
    # other. Rows are always read by their columns, never by this digest.
    def lock_key(*parts)
      high, low = Digest::SHA256.digest(parts.join(KEY_SEPARATOR)).unpack("l>l>")
      connection.execute(ApplicationRecord.sanitize_sql_array(["SELECT pg_advisory_xact_lock(?, ?)", high, low]))
    end

    # The company's row is created at generation 1 when it has none, then
    # read FOR SHARE, so an advance of this company's generation waits for
    # this write to commit. Both statements name this one company only.
    def locked_generation(company_id)
      connection.execute(ApplicationRecord.sanitize_sql_array([<<~SQL.squish, company_id]))
        INSERT INTO ownership_generations (company_id, generation) VALUES (?, 1)
        ON CONFLICT (company_id) DO NOTHING
      SQL
      connection.select_value(ApplicationRecord.sanitize_sql_array([<<~SQL.squish, company_id]))
        SELECT generation FROM ownership_generations WHERE company_id = ? FOR SHARE
      SQL
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
    def write_outbox(rows, generation)
      return if rows.empty?

      connection.execute(ApplicationRecord.sanitize_sql_array(["SELECT pg_advisory_xact_lock(?)", OUTBOX_LOCK_KEY]))
      OutboxSnapshot.insert_all!(rows.map { |row| OutboxFields.row(row, generation:) })
    end

    def connection
      ApplicationRecord.connection
    end
    private_class_method :connection
  end
end
