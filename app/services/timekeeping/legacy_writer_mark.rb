# frozen_string_literal: true

module Timekeeping
  # Marks a transaction's legacy writes so a database guard can tell them from
  # writes that bypass the gateway.
  #
  # SET LOCAL lasts until the outermost transaction ends. When the writer
  # joins a caller's transaction, the previous value is put back after the
  # write, so the caller's later statements are not marked as legacy writes.
  # That holds when the write raises too, since the caller may rescue and go
  # on in the same transaction.
  module LegacyWriterMark
    # A fixed literal, as ProjectionConsumer::MARK_PROJECTION_WRITER_SQL is.
    MARK_LEGACY_WRITER_SQL = "SET LOCAL miru.writer = 'legacy_gateway'"
    READ_WRITER_SQL = "SELECT current_setting('miru.writer', true)"
    RESTORE_WRITER_SQL = "SELECT set_config('miru.writer', ?, true)"

    module_function

    # Runs the block with the legacy writer mark set on connection and
    # returns the block's result.
    def call(connection)
      previous = connection.select_value(READ_WRITER_SQL)
      connection.execute(MARK_LEGACY_WRITER_SQL)
      begin
        result = yield
      rescue StandardError
        restore_after_failure(connection, previous)
        raise
      end
      restore(connection, previous)
      result
    end

    # A NULL previous value is restored as an empty string.
    def restore(connection, previous)
      connection.select_value(ActiveRecord::Base.sanitize_sql_array([RESTORE_WRITER_SQL, previous.to_s]))
    end

    # A failed SQL statement aborts the whole transaction, which can then only
    # roll back, and the rollback clears the setting. The restore cannot run
    # then, and its own error must not hide the write's.
    def restore_after_failure(connection, previous)
      restore(connection, previous)
    rescue ActiveRecord::StatementInvalid
      nil
    end
  end
end
