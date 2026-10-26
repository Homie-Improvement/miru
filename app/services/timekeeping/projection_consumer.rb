# frozen_string_literal: true

module Timekeeping
  # The only writer of the timesheet_entries projection
  # (docs/architecture/timekeeping-soa.md section 5.4). It applies one snapshot
  # batch in one transaction, so a batch is applied whole or not at all: the
  # relay re-sends a batch that did not get a 200.
  #
  # A batch is refused as a whole when any snapshot carries a generation the
  # ownership record does not accept, or names another company than the
  # stored row (409 stale_generation, as the contract answers any refused
  # snapshot), or breaks the contract or files an entry under another
  # company's project (422 invalid_snapshot). Company reports reach entries
  # through clients and projects, so that last check keeps one company's entry
  # out of another company's reports.
  class ProjectionConsumer
    Result = Data.define(:status, :body)

    STALE_GENERATION = Result.new(status: 409, body: { "reason" => "stale_generation" }.freeze)
    INVALID_SNAPSHOT = Result.new(status: 422, body: { "reason" => "invalid_snapshot" }.freeze)

    # A fixed literal, set only for this transaction, so a database guard can
    # tell projection writes apart and the mark never reaches another request
    # that reuses the pooled connection.
    MARK_PROJECTION_WRITER_SQL = "SET LOCAL miru.writer = 'projection'"

    # Raised inside the transaction to roll the whole batch back.
    class Refused < StandardError
      attr_reader :result

      def initialize(result)
        @result = result
        super(result.body.fetch("reason"))
      end
    end

    def self.call(batch:, idempotency_key: nil)
      new(batch:, idempotency_key:).call
    end

    def initialize(batch:, idempotency_key:)
      @batch = batch
      @idempotency_key = idempotency_key
    end

    def call
      items = SnapshotBatch.parse(@batch)
      return INVALID_SNAPSHOT unless items

      apply(items)
    rescue Refused => refusal
      refusal.result
    rescue ActiveRecord::InvalidForeignKey
      INVALID_SNAPSHOT
    end

    private

      def connection
        TimesheetEntry.connection
      end

      def apply(items)
        TimesheetEntry.transaction(requires_new: true) do
          connection.execute(MARK_PROJECTION_WRITER_SQL)
          refuse_stale_generations!(items)
          stored_companies = lock_stored_rows(items.map(&:entry_id))
          refuse_company_mismatch!(items, stored_companies)
          refuse_foreign_projects!(items)

          applied = items.count { |item| upsert(item) }
          Result.new(status: 200, body: { "applied" => applied, "ignored" => items.size - applied })
        end
      end

      # The share lock makes an ownership flip wait for this batch, so no
      # previous-generation snapshot can commit after the flip has.
      def refuse_stale_generations!(items)
        ownership = TimekeepingOwnership.lock("FOR SHARE").find(TimekeepingOwnership::SINGLETON_ID)
        accepted = items.all? do |item|
          ownership.snapshot_generation_accepted?(generation: item.generation, outbox_position: item.outbox_position)
        end
        raise Refused, STALE_GENERATION unless accepted
      end

      # Locks the batch's existing rows in id order, so two batches touching the
      # same entries cannot deadlock, and returns { id => stored company_id }.
      def lock_stored_rows(entry_ids)
        connection.select_rows(TimesheetEntry.sanitize_sql_array([<<~SQL.squish, entry_ids.uniq]))
          SELECT id, company_id FROM timesheet_entries WHERE id IN (?) ORDER BY id FOR UPDATE
        SQL
          .to_h
      end

      # A stored row without a company_id counts as a mismatch, so no snapshot
      # can claim a row whose tenant is unknown.
      def refuse_company_mismatch!(items, stored_companies)
        mismatch = items.any? do |item|
          stored_companies.key?(item.entry_id) && stored_companies[item.entry_id] != item.company_id
        end
        raise Refused, STALE_GENERATION if mismatch
      end

      # The share lock keeps each project on its client until this batch commits.
      def refuse_foreign_projects!(items)
        project_companies = connection.select_rows(TimesheetEntry.sanitize_sql_array([<<~SQL.squish, items.map(&:project_id).uniq]))
          SELECT projects.id, clients.company_id
          FROM projects INNER JOIN clients ON clients.id = projects.client_id
          WHERE projects.id IN (?)
          FOR SHARE OF projects
        SQL
          .to_h
        foreign = items.any? { |item| project_companies[item.project_id] != item.company_id }
        raise Refused, INVALID_SNAPSHOT if foreign
      end

      # One statement per snapshot, because a batch can hold several versions
      # of one entry and PostgreSQL refuses an upsert that touches a row twice.
      # The version compare sits in the statement itself, so a concurrent
      # delivery can never store a lower version over a higher one. Returns
      # whether the snapshot was applied.
      def upsert(item)
        return true if connection.select_value(upsert_sql(item.row))

        # Not applied: either the stored version is not lower, or an earlier
        # snapshot of this batch or a concurrent first insert stored the id
        # under another company, which the statement's company guard skipped.
        stored_company = connection.select_value(TimesheetEntry.sanitize_sql_array(
          ["SELECT company_id FROM timesheet_entries WHERE id = ? FOR UPDATE", item.entry_id]
        ))
        raise Refused, STALE_GENERATION if stored_company != item.company_id

        false
      end

      def upsert_sql(row)
        columns = row.keys.map { |column| connection.quote_column_name(column) }
        values = row.values.map { |value| connection.quote(value) }
        updates = columns.reject { |column| column == connection.quote_column_name("id") }
          .map { |column| "#{column} = EXCLUDED.#{column}" }

        <<~SQL.squish
          INSERT INTO timesheet_entries (#{columns.join(", ")}) VALUES (#{values.join(", ")})
          ON CONFLICT (id) DO UPDATE SET #{updates.join(", ")}
          WHERE timesheet_entries.version < EXCLUDED.version
            AND timesheet_entries.company_id = EXCLUDED.company_id
          RETURNING id
        SQL
      end
  end
end
