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
