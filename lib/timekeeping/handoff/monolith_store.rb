# frozen_string_literal: true

module Timekeeping
  module Handoff
    # The checkpoint store over the monolith's prepared tables, created by
    # db/migrate/20261025120000_prepare_monolith_for_timekeeping.rb. Every
    # row shape, count and checksum comes from Checkpoint; this class only
    # reads and writes. It touches the checkpoint tables, the entries id
    # sequence and, read only, entry_outbox_items: never a billing table.
    class MonolithStore
      include Store

      # The order rows are read in. The checksum ignores row order; a fixed
      # order only keeps exports easy to compare by eye. reservations has no
      # primary key, so every column that tells two rows apart is listed.
      READ_ORDER = {
        "entries" => %w[id],
        "reservations" => %w[company_id entry_id created_at operation_id state],
        "invoice_operations" => %w[id],
        "entry_audits" => %w[id],
        "idempotency_records" => %w[id]
      }.freeze

      # Entries go in first and come out last, because reservations and
      # entry_audits hold composite foreign keys to them.
      LOAD_ORDER = %w[entries reservations invoice_operations entry_audits idempotency_records].freeze
      INSERT_BATCH_SIZE = 500

      def initialize(connection:)
        @connection = connection
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
      # whole replacement back. The outbox, the invoice operation intents and
      # the entry id sequence are left alone.
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
          connection.execute("LOCK TABLE #{LOAD_ORDER.map { |table| connection.quote_table_name(table) }.join(', ')} IN EXCLUSIVE MODE")
          refuse_older_checkpoint_versions!(checkpoint.rows.fetch("entries"))
          LOAD_ORDER.reverse_each { |table| connection.execute("DELETE FROM #{connection.quote_table_name(table)}") }
          LOAD_ORDER.each { |table| insert_rows(table, checkpoint.rows.fetch(table)) }

          stored = Checkpoint.new(rows: LOAD_ORDER.index_with { |table| read_rows(table) }, digest: checkpoint.digest)
          refuse_mismatches!("the loaded rows do not match the checkpoint", Checkpoint.verify(stored))
          Checkpoint.build(tables: stored.rows)
        end
      end

      def highest_outbox_position
        connection.select_value("SELECT COALESCE(MAX(outbox_position), 0) FROM entry_outbox_items").to_i
      end

      # Returns the id the sequence hands out next.
      #
      # The lock keeps writers that draw ids from the sequence out until the
      # caller's transaction ends. The comparison and the setval run in one
      # statement, so no value read earlier can move the sequence backwards.
      def advance_entry_id_sequence(above:)
        target = Integer(above)
        sequence = connection.select_value("SELECT pg_get_serial_sequence('entries', 'id')")

        connection.transaction do
          connection.execute("LOCK TABLE entries IN EXCLUSIVE MODE")
          connection.select_value(<<~SQL.squish)
            SELECT setval(#{connection.quote(sequence)}, #{target}, true)
            FROM #{sequence}
            WHERE #{next_id_sql} < #{target} + 1
          SQL
          connection.select_value("SELECT #{next_id_sql} FROM #{sequence}").to_i
        end
      end

      private

        attr_reader :connection

        # Before the first nextval the sequence hands out last_value itself.
        def next_id_sql
          "CASE WHEN is_called THEN last_value + 1 ELSE last_value END"
        end

        def read_rows(table)
          check_columns!(table)
          order = READ_ORDER.fetch(table).map { |column| connection.quote_column_name(column) }.join(", ")
          result = connection.select_all("SELECT * FROM #{connection.quote_table_name(table)} ORDER BY #{order}")
          result.cast_values.map { |values| result.columns.zip(values).to_h }
        end

        # A column on only one side would be dropped or left unfilled.
        def check_columns!(table)
          stored = connection.columns(table).map(&:name)
          canonical = Checkpoint::TABLES.fetch(table)
          unknown = stored - canonical
          missing = canonical - stored
          raise Checkpoint::ShapeError, "#{table}: columns with no home in the checkpoint: #{unknown.join(', ')}" if unknown.any?
          raise Checkpoint::ShapeError, "#{table}: checkpoint columns the table lacks: #{missing.join(', ')}" if missing.any?
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
          companies = connection.select_rows("SELECT company_id, id, version FROM entries").filter_map do |company_id, id, version|
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
          stored_columns = connection.columns(table).index_by(&:name)
          column_list = columns.map { |column| connection.quote_column_name(column) }.join(", ")

          rows.each_slice(INSERT_BATCH_SIZE) do |batch|
            values = batch.map do |row|
              "(#{columns.map { |column| sql_literal(row.fetch(column), stored_columns.fetch(column)) }.join(', ')})"
            end
            connection.execute("INSERT INTO #{connection.quote_table_name(table)} (#{column_list}) VALUES #{values.join(', ')}")
          end
        rescue ActiveRecord::StatementInvalid => error
          raise Store::Error, "#{table}: #{error.message}"
        end

        # Floats go in as quoted text: Float#to_s is the shortest decimal that
        # reads back to the same bits, and an unquoted -0.0 would be parsed as
        # the negation of the number zero and stored as 0.
        def sql_literal(value, column)
          # Column#sql_type names an array column's element type only.
          sql_type = column.array? ? "#{column.sql_type}[]" : column.sql_type
          literal =
            if value.is_a?(Float)
              connection.quote(value.to_s)
            else
              connection.quote(connection.lookup_cast_type(sql_type).serialize(value))
            end
          "#{literal}::#{sql_type}"
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
