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
  # company's project or agent (422 invalid_snapshot). Company reports reach
  # entries through clients and projects, so the project check keeps one
  # company's entry out of another company's reports.
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
      record_stale_generation(items) if refusal.result == STALE_GENERATION
      refusal.result
    rescue ActiveRecord::InvalidForeignKey
      INVALID_SNAPSHOT
    end

    private

      def connection
        TimesheetEntry.connection
      end

      # Runs after the refused batch has rolled back, so the record survives
      # for the stale_generation alert (section 11.3): one row per company in
      # the batch, with the handoff step in progress at this moment. A backstop
      # for a database fault here: the 409 is already decided, and a lost
      # record must not replace it.
      def record_stale_generation(items)
        handoff_step = TimekeepingOwnership.current.handoff_step
        rows = items.map(&:company_id).uniq.map { |company_id| { company_id:, handoff_step: } }
        TimekeepingStaleGenerationRefusal.insert_all!(rows)
      rescue StandardError => error
        Rails.logger.warn("stale_generation refusal not recorded: #{error.class}")
      end

      def apply(items)
        TimesheetEntry.transaction(requires_new: true) do
          connection.execute(MARK_PROJECTION_WRITER_SQL)
          receipts = SnapshotDeliveryReceipts.new(key: @idempotency_key, batch: @batch, company_ids: items.map(&:company_id))
          receipts.stored_answer || receipts.store(write(items))
        end
      end

      def write(items)
        refuse_stale_generations!(items)
        stored_rows = lock_stored_rows(items.map(&:entry_id))
        refuse_company_mismatch!(items, stored_rows.transform_values(&:first))
        # Only a snapshot that will be written can file an entry under a
        # project or agent; one the version guard ignores names a project or
        # agent that may have been deleted since, and must still be ignored.
        applying = applying_items(items, stored_rows.transform_values(&:last))
        refuse_foreign_projects!(applying)
        refuse_foreign_agents!(applying)

        applied = items.count { |item| upsert(item) }
        Result.new(status: 200, body: { "applied" => applied, "ignored" => items.size - applied })
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
      # same entries cannot deadlock, and returns
      # { id => [stored company_id, stored version] }.
      def lock_stored_rows(entry_ids)
        connection.select_rows(TimesheetEntry.sanitize_sql_array([<<~SQL.squish, entry_ids.uniq]))
          SELECT id, company_id, version FROM timesheet_entries WHERE id IN (?) ORDER BY id FOR UPDATE
        SQL
          .to_h { |id, company_id, version| [id, [company_id, version]] }
      end

      # The snapshots the version guard will write, in outbox order: each one
      # newer than the stored row and than any earlier snapshot of its entry
      # in this batch.
      def applying_items(items, stored_versions)
        versions = stored_versions.dup
        items.select do |item|
          newer = versions[item.entry_id].nil? || item.version > versions[item.entry_id]
          versions[item.entry_id] = item.version if newer
          newer
        end
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

      # An agent of another company or user would show its name beside this
      # company's entry. An agent id that names no agent row is not decided
      # here: the timesheet_entries -> agents foreign key, which the schema
      # still keeps, refuses it. The share lock keeps each agent's company and
      # user until this batch commits.
      def refuse_foreign_agents!(items)
        agent_ids = items.filter_map(&:agent_id).uniq
        return if agent_ids.empty?

        agents = connection.select_rows(TimesheetEntry.sanitize_sql_array([<<~SQL.squish, agent_ids]))
          SELECT id, company_id, user_id FROM agents WHERE id IN (?) FOR SHARE
        SQL
          .to_h { |id, company_id, user_id| [id, [company_id, user_id]] }
        foreign = items.any? do |item|
          owner = agents[item.agent_id]
          owner && owner != [item.company_id, item.user_id]
        end
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
