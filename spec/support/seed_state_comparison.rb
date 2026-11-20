# frozen_string_literal: true

# Reads what a seed load left in the database, so specs can check that a
# restored seed capture matches the load it was taken from.
module SeedStateComparison
  module_function

  # [row count, md5 of the rows] per application table. Rows are hashed as
  # text sorted by that text, so tables with no primary key (reservations,
  # users_roles) and duplicate rows are compared too.
  def table_digests(connection = ActiveRecord::Base.connection)
    tables = connection.tables - Timekeeping::SeedDispositionRecorder::METADATA_TABLES
    tables.sort.index_with do |table|
      row = connection.select_one(<<~SQL)
        SELECT count(*) AS row_count,
               md5(coalesce(string_agg(t::text, E'\\n' ORDER BY t::text), '')) AS digest
        FROM #{connection.quote_table_name(table)} t
      SQL
      [row["row_count"].to_i, row["digest"]]
    end
  end

  # [last_value, is_called] per sequence, read from each sequence itself:
  # pg_sequences has no is_called column and shows NULL for a sequence that
  # never supplied a value.
  def sequence_states(connection = ActiveRecord::Base.connection)
    names = connection.select_values(<<~SQL)
      SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relkind = 'S' AND n.nspname = current_schema()
    SQL
    names.sort.index_with do |name|
      row = connection.select_one("SELECT last_value, is_called FROM #{connection.quote_table_name(name)}")
      [row["last_value"].to_i, row["is_called"]]
    end
  end
end
