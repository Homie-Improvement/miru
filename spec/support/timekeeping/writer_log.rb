# frozen_string_literal: true

# The writer log the single-writer guard (docs/architecture/timekeeping-soa.md
# section 12.2) reads to find who changed timesheet_entries rows, and the rules
# it judges those writers by.
module TimekeepingWriterLog
  # The only miru.writer mark each owner state accepts. The strings match the
  # SET LOCAL marks in app/services/timekeeping/gateway.rb and
  # app/services/timekeeping/projection_consumer.rb. A NULL, empty or any other
  # writer is in no list, so it is a violation in every state.
  ALLOWED_WRITERS = {
    "legacy" => ["legacy_gateway"].freeze,
    "timekeeping" => ["projection"].freeze,
    "rollback" => ["projection"].freeze
  }.freeze

  # Every writer section 10.1 names, keyed by its source path, mapped to the
  # guard case that drives it. The invoice reservation boundary replaces code
  # in two files, so both map to one case.
  SECTION_10_1_WRITERS = {
    "app/controllers/api/v1/timesheet_entry_controller.rb" => :web_mobile_controller,
    "app/controllers/api/v1/timesheet_entry/bulk_action_controller.rb" => :bulk_controller,
    "app/controllers/api/v1/cli/timesheet_entries_controller.rb" => :cli_controller,
    "app/controllers/api/v1/agent/timesheet_entries_controller.rb" => :agent_controller,
    "app/services/imports/harvest_time_entries_importer.rb" => :harvest_import,
    "app/models/invoice.rb" => :invoice_reservation,
    "app/models/invoice_line_item.rb" => :invoice_reservation,
    "app/models/agent.rb" => :agent_destroy
  }.freeze

  SECTION_10_1_HEADING = "**Every writer goes through the gateway.**"
  BACKTICKED_TOKEN = /`([^`]+)`/
  # A relative Ruby source path with an optional line number, such as
  # app/models/agent.rb:17. Method names and command names do not match.
  RELATIVE_RUBY_PATH = %r{\A(?!/)([\w./-]+\.rb)(?::\d+)?\z}
  BULLET_START = "- "

  # A real UNLOGGED table and a function in the public schema, not a TEMP table
  # and a pg_temp function: those exist only for the session that creates them,
  # so they would miss writes from every other session, the apps' own included.
  # None of this belongs in db/migrate or db/schema.rb: it lives only while a
  # guard runs.
  #
  # The function stores NULL for an unmarked write. A pooled session that once
  # ran SET LOCAL miru.writer reads '' afterwards rather than NULL, and both
  # mean the same thing: no writer marked this write.
  CREATE_LOG_TABLE_SQL = <<~SQL
    CREATE UNLOGGED TABLE IF NOT EXISTS public.miru_writer_log (
      id bigserial PRIMARY KEY,
      writer text,
      company_id bigint,
      op text NOT NULL,
      entry_id bigint,
      backend_pid integer NOT NULL
    )
  SQL

  CREATE_RECORD_FUNCTION_SQL = <<~SQL
    CREATE OR REPLACE FUNCTION public.miru_writer_log_record() RETURNS trigger AS $$
    DECLARE
      changed timesheet_entries%ROWTYPE;
    BEGIN
      IF TG_OP = 'DELETE' THEN
        changed := OLD;
      ELSE
        changed := NEW;
      END IF;
      INSERT INTO public.miru_writer_log (writer, company_id, op, entry_id, backend_pid)
      VALUES (NULLIF(current_setting('miru.writer', true), ''), changed.company_id, TG_OP, changed.id, pg_backend_pid());
      RETURN NULL;
    END
    $$ LANGUAGE plpgsql
  SQL

  # Dropping first means a trigger left by a run that crashed before remove!
  # is replaced, never doubled.
  DROP_TRIGGER_SQL = "DROP TRIGGER IF EXISTS miru_writer_log_trigger ON timesheet_entries"
  CREATE_TRIGGER_SQL = <<~SQL
    CREATE TRIGGER miru_writer_log_trigger AFTER INSERT OR UPDATE OR DELETE ON timesheet_entries
      FOR EACH ROW EXECUTE FUNCTION public.miru_writer_log_record()
  SQL
  DROP_FUNCTION_SQL = "DROP FUNCTION IF EXISTS public.miru_writer_log_record()"
  DROP_LOG_TABLE_SQL = "DROP TABLE IF EXISTS public.miru_writer_log"
  # DELETE rather than a table-emptying statement the reset-site scan in
  # spec/meta/test_database_cleanup_reset_sites_spec.rb would refuse.
  CLEAR_LOG_SQL = "DELETE FROM public.miru_writer_log"
  SELECT_ROWS_SQL = "SELECT writer, company_id, op, backend_pid FROM public.miru_writer_log ORDER BY id"

  module_function

  # Creates the log table, the record function and the trigger. Safe to run
  # again, and over objects a crashed run left behind. A leftover table keeps
  # the dead run's rows, so the log is emptied before the trigger goes back on.
  def install!(connection)
    [CREATE_LOG_TABLE_SQL, CLEAR_LOG_SQL, CREATE_RECORD_FUNCTION_SQL, DROP_TRIGGER_SQL, CREATE_TRIGGER_SQL].each do |sql|
      connection.execute(sql)
    end
    nil
  end

  # Drops the trigger, the function and the table. Safe to run when any or all
  # of them are already gone.
  def remove!(connection = ActiveRecord::Base.connection)
    [DROP_TRIGGER_SQL, DROP_FUNCTION_SQL, DROP_LOG_TABLE_SQL].each { |sql| connection.execute(sql) }
    nil
  end

  # Installs the log for the block and removes it however the block ends, so
  # no trigger outlives the guard.
  def guarding(connection)
    install!(connection)
    yield
  ensure
    remove!(connection)
  end

  def clear!(connection = ActiveRecord::Base.connection)
    connection.execute(CLEAR_LOG_SQL)
    nil
  end

  # Every logged write, oldest first, as { writer:, company_id:, op: }, plus
  # backend_pid: (the writing session's server process id) when asked.
  def rows(connection = ActiveRecord::Base.connection, include_backend_pid: false)
    connection.select_all(SELECT_ROWS_SQL).map do |row|
      logged = { writer: row["writer"], company_id: row["company_id"], op: row["op"] }
      include_backend_pid ? logged.merge(backend_pid: row["backend_pid"]) : logged
    end
  end

  # The rows whose writer the state does not allow. The state is checked
  # before the rows, so an unknown state raises even when there are none.
  def violations(state:, rows:)
    allowed = ALLOWED_WRITERS.fetch(state) do
      raise ArgumentError, "unknown Timekeeping owner state #{state.inspect}; " \
                           "expected one of #{ALLOWED_WRITERS.keys.join(', ')}"
    end
    rows.reject { |row| allowed.include?(row.fetch(:writer)) }
  end

  # The source paths in the bullet list that follows the section 10.1 heading,
  # in document order. Raises when the heading is missing, the list is empty,
  # or an item names no path.
  def section_10_1_paths(text)
    section_10_1_items(text).flat_map do |item|
      paths = item.scan(BACKTICKED_TOKEN).flatten.filter_map { |token| token[RELATIVE_RUBY_PATH, 1] }
      raise ArgumentError, "section 10.1 writer item names no source path: #{item.inspect}" if paths.empty?

      paths
    end.uniq
  end

  # Raises naming every path the doc lists that writers lacks, and every path
  # writers holds that the doc does not list.
  def check_section_10_1!(text:, writers: SECTION_10_1_WRITERS)
    doc_paths = section_10_1_paths(text)
    missing_from_writers = doc_paths - writers.keys
    missing_from_doc = writers.keys - doc_paths
    return if missing_from_writers.empty? && missing_from_doc.empty?

    raise ArgumentError, "section 10.1 writer list and SECTION_10_1_WRITERS differ; " \
                         "missing from the writers: #{missing_from_writers.inspect}; " \
                         "missing from the doc: #{missing_from_doc.inspect}"
  end

  # Raises naming every writer case that case_names does not cover.
  def require_cases!(case_names)
    uncovered = SECTION_10_1_WRITERS.values.uniq - case_names.to_a
    return if uncovered.empty?

    raise ArgumentError, "section 10.1 writers with no case: #{uncovered.inspect}"
  end

  # Each bullet item of the list, continuation lines joined. The list starts
  # after the heading line and any blank lines, and ends at the first line that
  # neither starts an item nor continues one, so later paragraphs are not read.
  def section_10_1_items(text)
    lines = text.lines.map(&:chomp)
    heading_index = lines.index { |line| line.include?(SECTION_10_1_HEADING) }
    raise ArgumentError, "no line contains the section 10.1 heading #{SECTION_10_1_HEADING}" unless heading_index

    following = lines.drop(heading_index + 1).drop_while { |line| line.strip.empty? }
    items = following.each_with_object([]) do |line, collected|
      if line.start_with?(BULLET_START)
        collected << line
      elsif collected.any? && line.match?(/\A\s+\S/)
        collected[-1] = "#{collected.last} #{line.strip}"
      else
        break collected
      end
    end
    raise ArgumentError, "the section 10.1 writer list is empty" if items.empty?

    items
  end
  private_class_method :section_10_1_items
end
