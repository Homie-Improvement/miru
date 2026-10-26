# frozen_string_literal: true

module Timekeeping
  module Handoff
    # The checkpoint store over one database's checkpoint tables, shared by
    # the monolith and Timekeeping. Every row shape, count and checksum comes
    # from Checkpoint; this class only reads and writes. It touches the
    # checkpoint tables and their id sequences: never an outbox, the
    # admission state or a billing table.
    #
    # The two applications name some checkpoint tables differently, so each
    # store is built with a map from checkpoint table to its own table name.
    # Export and load both read that one map.
    class TableStore
      include Store

      # The order rows are read in. The checksum ignores row order; a fixed
      # order only keeps exports easy to compare by eye. reservations has no
      # primary key, so every column that tells two rows apart is listed.
      READ_ORDER = {
        "entries" => %w[id],
        "reservations" => %w[company_id entry_id created_at operation_id state],
        "invoice_operations" => %w[id],
        "entry_audits" => %w[id],
        "idempotency_records" => %w[id],
        "service_idempotency_receipts" => %w[id]
      }.freeze

      # A table goes in after, and comes out before, every table it holds a
      # foreign key to: reservations to entries, and in Timekeeping also to the
      # invoice_operations row named by invoice_operation_id.
      LOAD_ORDER = %w[
        entries invoice_operations reservations entry_audits idempotency_records service_idempotency_receipts
      ].freeze
      INSERT_BATCH_SIZE = 500

      # The tables whose rows go in with the ids the checkpoint carries. Each
      # one's id sequence is moved above the highest loaded id before the load
      # commits, or the next ordinary insert would collide with a loaded row.
      # The entries sequence is left to advance_entry_id_sequence, which the
      # handoff runs as a step of its own (docs/architecture/timekeeping-soa.md
      # section 10.5).
      LOADED_ID_SEQUENCE_TABLES = %w[
        invoice_operations entry_audits idempotency_records service_idempotency_receipts
      ].freeze

      # tables: { checkpoint table => this database's table name }, naming a
      # table for every table in Checkpoint::TABLES.
      def initialize(connection:, tables:)
        unless tables.keys.sort == Checkpoint::TABLES.keys.sort
          raise ArgumentError, "tables must name a table for each of: #{Checkpoint::TABLES.keys.join(', ')}"
        end

        @connection = connection
        @tables = tables.dup.freeze
      end

      # A transaction the caller already opened would fix the isolation level
      # and snapshot before export starts, so Rails' refusal to set an
      # isolation level inside one is the check that export reads alone.
      def export_checkpoint
        connection.transaction(isolation: :repeatable_read) do
          connection.execute("SET TRANSACTION READ ONLY")
          tables = Checkpoint::TABLES.keys.index_with { |table| read_rows(table) }
          refuse_unsettled_operations!(tables.fetch("invoice_operations"))
          Checkpoint.build(tables:)
        end
      end

      # Replaces the checkpoint tables with the checkpoint's rows and returns
      # the checkpoint read back from them. Any refusal or failure rolls the
      # whole replacement back. The entry id sequence is left alone; the id
      # sequences of the other loaded tables only move forward.
      #
      # A transaction the caller already opened is refused: the load would
      # join it, and a caller that rescued a failed load could still commit
      # the half-replaced tables.
      def load_checkpoint(checkpoint)
        if connection.transaction_open?
          raise Store::Error, "refusing to load a checkpoint inside an open transaction; call load_checkpoint outside one"
        end

        refuse_mismatches!("the checkpoint does not match its own digest", Checkpoint.verify(checkpoint))

        connection.transaction do
          LOAD_ORDER.each { |table| check_columns!(table) }
          connection.execute("LOCK TABLE #{LOAD_ORDER.map { |table| quoted_table(table) }.join(', ')} IN EXCLUSIVE MODE")
          check_load_allowed!
          refuse_older_checkpoint_versions!(checkpoint.rows.fetch("entries"))
          LOAD_ORDER.reverse_each { |table| connection.execute("DELETE FROM #{quoted_table(table)}") }
          LOAD_ORDER.each { |table| insert_rows(table, checkpoint.rows.fetch(table)) }
          advance_loaded_id_sequences(checkpoint)

          stored = Checkpoint.new(rows: LOAD_ORDER.index_with { |table| read_rows(table) }, digest: checkpoint.digest)
          refuse_mismatches!("the loaded rows do not match the checkpoint", Checkpoint.verify(stored))
          Checkpoint.build(tables: stored.rows)
        end
      end

      # Returns the id the sequence hands out next.
      #
      # The lock keeps writers that draw ids from the sequence out until the
      # caller's transaction ends. The comparison and the setval run in one
      # statement, so no value read earlier can move the sequence backwards.
      def advance_entry_id_sequence(above:)
        target = Integer(above)

        connection.transaction do
          connection.execute("LOCK TABLE #{quoted_table('entries')} IN EXCLUSIVE MODE")
          advance_sequence("entries", target)
        end
      end

      private

        attr_reader :connection

        # Runs inside the load transaction, after the checkpoint tables are
        # locked and before anything is deleted. A store raises Store::Error
        # here to refuse a load its own state does not allow.
        def check_load_allowed!; end

        def table_name(table)
          @tables.fetch(table)
        end

        def quoted_table(table)
          connection.quote_table_name(table_name(table))
        end

        # Moves the table's id sequence so its next id is above target, never
        # backwards, and returns that next id.
        def advance_sequence(table, target)
          sequence = connection.select_value("SELECT pg_get_serial_sequence(#{connection.quote(table_name(table))}, 'id')")
          connection.select_value(<<~SQL.squish)
            SELECT setval(#{connection.quote(sequence)}, #{Integer(target)}, true)
            FROM #{sequence}
            WHERE #{next_id_sql} < #{Integer(target)} + 1
          SQL
          connection.select_value("SELECT #{next_id_sql} FROM #{sequence}").to_i
        end

        def advance_loaded_id_sequences(checkpoint)
          LOADED_ID_SEQUENCE_TABLES.each do |table|
            highest = checkpoint.rows.fetch(table).filter_map { |row| row["id"] }.max
            advance_sequence(table, highest) if highest
          end
        end

        # Before the first nextval the sequence hands out last_value itself.
        def next_id_sql
          "CASE WHEN is_called THEN last_value + 1 ELSE last_value END"
        end

        def read_rows(table)
          check_columns!(table)
          order = READ_ORDER.fetch(table).map { |column| connection.quote_column_name(column) }.join(", ")
          result = connection.select_all("SELECT * FROM #{quoted_table(table)} ORDER BY #{order}")
          jsonb_columns = result.columns.select { |column| result.column_types[column]&.type == :jsonb }

          result.cast_values.zip(result.rows).map do |values, raw_values|
            row = result.columns.zip(values).to_h
            jsonb_columns.each { |column| row[column] = parse_jsonb(raw_values[result.columns.index(column)]) }
            row
          end
        end

        # Active Record's jsonb cast turns every decimal into a Float, which
        # rounds a number finer than a double. BigDecimal keeps it as stored.
        # The cast also reads JSON null as nil, the same as SQL NULL.
        def parse_jsonb(text)
          return if text.nil?

          value = JSON.parse(text, decimal_class: BigDecimal)
          value.nil? ? Checkpoint::JSON_NULL : value
        end

        # A column on only one side would be dropped or left unfilled.
        def check_columns!(table)
          stored = connection.columns(table_name(table)).map(&:name)
          canonical = Checkpoint::TABLES.fetch(table)
          unknown = stored - canonical
          missing = canonical - stored
          if unknown.any?
            raise Checkpoint::ShapeError, "#{table_name(table)}: columns with no home in the checkpoint: #{unknown.join(', ')}"
          end
          if missing.any?
            raise Checkpoint::ShapeError, "#{table_name(table)}: checkpoint columns the table lacks: #{missing.join(', ')}"
          end
        end

        def refuse_mismatches!(reason, mismatches)
          return if mismatches.empty?

          places = mismatches.map { |mismatch| "#{mismatch[:table]} company_id #{mismatch[:company_id]}" }
          raise Store::Error, "#{reason}: #{places.join(', ')}"
        end

        # Versions never go backwards: a stored entry newer than the
        # checkpoint's copy of it would be overwritten by an older one.
        def refuse_older_checkpoint_versions!(entries)
          checkpoint_versions = entries.to_h { |row| [[row["company_id"], row["id"]], row["version"]] }
          stored = connection.select_rows("SELECT company_id, id, version FROM #{quoted_table('entries')}")
          companies = stored.filter_map do |company_id, id, version|
            checkpoint_version = checkpoint_versions[[company_id, id]]
            company_id if checkpoint_version && version > checkpoint_version
          end.uniq.sort
          return if companies.empty?

          raise Store::Error,
            "entries: the store holds newer entry versions than the checkpoint for company_id #{companies.join(', ')}"
        end

        # Every canonical column is written explicitly, ids and timestamps
        # included, so no column default fills in a value.
        def insert_rows(table, rows)
          columns = Checkpoint::TABLES.fetch(table)
          stored_columns = connection.columns(table_name(table)).index_by(&:name)
          column_list = columns.map { |column| connection.quote_column_name(column) }.join(", ")

          rows.each_slice(INSERT_BATCH_SIZE) do |batch|
            values = batch.map do |row|
              "(#{columns.map { |column| LosslessSql.literal(connection, row.fetch(column), stored_columns.fetch(column)) }.join(', ')})"
            end
            connection.execute("INSERT INTO #{quoted_table(table)} (#{column_list}) VALUES #{values.join(', ')}")
          end
        rescue ActiveRecord::StatementInvalid => error
          raise Store::Error, "#{table_name(table)}: #{error.message}"
        end

        # The checkpoint carries only terminal invoice operations. A prepared
        # one means the source was not settled before export (section 10.5),
        # and skipping it would drop it on the next load.
        def refuse_unsettled_operations!(operations)
          companies = operations.filter_map { |row| row["company_id"] if row["state"] == "prepared" }.uniq.sort
          return if companies.empty?

          raise Store::Error,
            "invoice_operations: prepared operations remain for company_id #{companies.join(', ')}; settle them before export"
        end
    end
  end
end
