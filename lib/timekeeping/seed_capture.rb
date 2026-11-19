# frozen_string_literal: true

module Timekeeping
  # An in-memory copy of every row and sequence a seed load left in the
  # database, which can be restored into empty tables in a fraction of the
  # time db/seeds.rb takes to run.
  #
  # Rows are copied with PostgreSQL COPY, so every stored column comes back as
  # it was (ids and timestamps included), tables without a primary key and
  # duplicate rows included. Generated columns are left out of the copy because
  # PostgreSQL computes them again on insert.
  #
  # Sequence state is read from each sequence itself: the pg_sequences view
  # has no is_called column and shows NULL for a sequence that never supplied
  # a value, so it cannot reproduce the next id of an unused sequence.
  SeedCapture = Data.define(:tables, :sequences, :blobs) do
    const_set(:Table, Data.define(:name, :columns, :rows))
    const_set(:Sequence, Data.define(:name, :last_value, :called))
    const_set(:Blob, Data.define(:service_name, :key))
    const_set(:RestoreError, Class.new(StandardError))

    def self.take(connection:, tables:)
      new(
        tables: tables.sort.map { |table| copy_out(connection, table) }.freeze,
        sequences: read_sequences(connection).freeze,
        blobs: read_blobs(connection, tables).freeze
      )
    end

    def self.copy_out(connection, table)
      columns = copied_columns(connection, table)
      raw = connection.raw_connection
      rows = String.new(encoding: Encoding::BINARY)
      raw.copy_data("COPY #{connection.quote_table_name(table)} (#{column_list(connection, columns)}) TO STDOUT") do
        while (row = raw.get_copy_data)
          rows << row
        end
      end
      self::Table.new(name: table, columns: columns.freeze, rows: rows.freeze)
    end

    def self.copied_columns(connection, table)
      connection.select_values(<<~SQL.squish)
        SELECT attname FROM pg_attribute
        WHERE attrelid = #{connection.quote(connection.quote_table_name(table))}::regclass
          AND attnum > 0 AND NOT attisdropped AND attgenerated = ''
        ORDER BY attnum
      SQL
    end

    # The quoted column list a COPY statement names, in capture order.
    def self.column_list(connection, columns)
      columns.map { |column| connection.quote_column_name(column) }.join(", ")
    end

    def self.read_sequences(connection)
      names = connection.select_values(<<~SQL.squish)
        SELECT c.relname FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'S' AND n.nspname = current_schema()
        ORDER BY c.relname
      SQL
      names.map do |name|
        state = connection.select_one("SELECT last_value, is_called FROM #{connection.quote_table_name(name)}")
        self::Sequence.new(name:, last_value: state.fetch("last_value"), called: state.fetch("is_called"))
      end
    end

    # Attachment files live on disk under the storage service, outside the
    # database, so a restore has to check they are still there.
    def self.read_blobs(connection, tables)
      return [] unless tables.include?("active_storage_blobs")

      connection.select_rows("SELECT service_name, key FROM active_storage_blobs ORDER BY id")
        .map { |service_name, key| self::Blob.new(service_name:, key:) }
    end

    private_class_method :copy_out, :copied_columns, :read_sequences, :read_blobs

    # Restores the captured rows and sequence values into empty tables. Raises
    # RestoreError when an attachment file is missing (before anything is
    # written) or when any write fails; the row inserts are rolled back then.
    # PostgreSQL never rolls back setval, so sequences are set last, and a
    # caller that recovers from a failure resets them before loading again.
    def restore!(connection:)
      missing = blobs.reject { |blob| ActiveStorage::Blob.services.fetch(blob.service_name).exist?(blob.key) }
      raise self.class::RestoreError, "Seed attachment files are missing: #{missing.map(&:key).join(', ')}" if missing.any?

      connection.transaction do
        # Foreign-key triggers are off while loading so tables can be filled in
        # any order; every referenced row is in the same copy.
        connection.disable_referential_integrity { tables.each { |table| copy_in(connection, table) } }
        sequences.each { |sequence| set_sequence(connection, sequence) }
      end
    rescue ActiveRecord::ActiveRecordError, PG::Error => e
      raise self.class::RestoreError, "Restoring the seed capture failed: #{e.message}"
    end

    private

      def copy_in(connection, table)
        return if table.rows.empty?

        raw = connection.raw_connection
        columns = self.class.column_list(connection, table.columns)
        raw.copy_data("COPY #{connection.quote_table_name(table.name)} (#{columns}) FROM STDIN") do
          raw.put_copy_data(table.rows)
        end
      end

      def set_sequence(connection, sequence)
        connection.select_value(
          "SELECT setval(#{connection.quote(connection.quote_table_name(sequence.name))}::regclass, " \
          "#{connection.quote(sequence.last_value)}::bigint, #{connection.quote(sequence.called)}::boolean)"
        )
      end
  end
end
