# frozen_string_literal: true

require "digest"
require "pg"
require_relative "integrated_runtime"
require_relative "timekeeping_database_reset"

# Per-company content digests of the Timekeeping tenant state in both
# databases, so a spec can prove that a request "changes nothing" for a
# company by comparing a take before the request with a take after it.
#
# Each group digest is a SHA-256 over every matching row, ordered and read as
# the database's own row_to_json text. Counts alone would miss an update, and
# values decoded into Ruby would merge NULL with an empty string.
#
# timekeeping_url: is the Timekeeping DATABASE URL
# (ENV[TimekeepingDatabaseReset::DATABASE_URL_KEY]), not the runtime's HTTP
# address IntegratedRuntime#timekeeping_url. Its database name must end in
# _test, checked before any connection; no error raised here carries the URL.
#
# Not digested: timekeeping_stale_generation_refusals,
# invoice_operation_intents, invoice_operation_outbox_items, and rows with a
# NULL company_id. An entry_snapshot_receipts row lists its companies in
# company_ids, so a row listing several companies is in each one's digest.
module TenantStateDigest
  # predicate selects one company's rows with the company id bound as $1;
  # order makes the row order, and so the digest, stable between takes.
  Table = Data.define(:table, :predicate, :order)

  BY_COMPANY = "company_id = $1"
  BY_COMPANY_LIST = "$1 = ANY(company_ids)"
  BY_ID = "id"
  BY_OUTBOX_POSITION = "outbox_position"
  # reservations has no primary key; a whole-row comparison orders by every
  # column in table order, and stays complete if a column is added.
  BY_WHOLE_ROW = "t"

  GROUPS = {
    monolith: {
      projection: [Table.new("timesheet_entries", BY_COMPANY, BY_ID)],
      entries: [Table.new("entries", BY_COMPANY, BY_ID)],
      receipts: [Table.new("idempotency_records", BY_COMPANY, BY_ID),
                 Table.new("entry_snapshot_receipts", BY_COMPANY_LIST, BY_ID)],
      outbox: [Table.new("entry_outbox_items", BY_COMPANY, BY_OUTBOX_POSITION)],
      invoice_operations: [Table.new("invoice_operations", BY_COMPANY, BY_ID),
                           Table.new("reservations", BY_COMPANY, BY_WHOLE_ROW)]
    }.transform_values(&:freeze).freeze,
    timekeeping: {
      entries: [Table.new("entries", BY_COMPANY, BY_ID)],
      receipts: [Table.new("idempotency_receipts", BY_COMPANY, BY_ID),
                 Table.new("service_idempotency_receipts", BY_COMPANY, BY_ID)],
      outbox: [Table.new("outbox_snapshots", BY_COMPANY, BY_OUTBOX_POSITION)],
      invoice_operations: [Table.new("invoice_operations", BY_COMPANY, BY_ID),
                           Table.new("reservations", BY_COMPANY, BY_WHOLE_ROW)]
    }.transform_values(&:freeze).freeze
  }.freeze

  TABLE_FRAME = "T"
  ROW_FRAME = "R"
  URL_FORM = %r{\Apostgres(?:ql)?://}i

  module_function

  def take(company_id:, timekeeping_url:)
    require_test_database!(timekeeping_url)
    { monolith: monolith(company_id:), timekeeping: timekeeping(company_id:, timekeeping_url:) }
  end

  # A URL can name one database to libpq (a dbname parameter) and another to
  # Active Record (the path), so both readings must end in _test. A keyword
  # conninfo ("host=... dbname=...") has no Active Record reading at all, and
  # this module opens it only through libpq, so libpq's name is the one checked.
  def require_test_database!(timekeeping_url)
    if timekeeping_url.is_a?(String) && timekeeping_url.match?(URL_FORM)
      IntegratedRuntime.require_test_database_url!(timekeeping_url)
    else
      TestDatabaseGuard.require_test_database!(TimekeepingDatabaseReset.database_name(timekeeping_url))
    end
  end

  # Read uncached: a write through another connection, or the raw one, does
  # not clear Active Record's query cache, so a cached read would hide it.
  def monolith(company_id:)
    connection = ActiveRecord::Base.connection
    ActiveRecord::Base.uncached do
      digest_groups(GROUPS.fetch(:monolith)) do |table|
        connection.select_values(row_query(table, connection.quote_table_name(table.table)), "TenantStateDigest",
                                 [company_id])
      end
    end
  end

  # A missing database raises rather than digesting as empty: equal empty
  # takes before and after would claim a request changed nothing it never read.
  def timekeeping(company_id:, timekeeping_url:)
    require_test_database!(timekeeping_url)
    name = TimekeepingDatabaseReset.database_name(timekeeping_url)
    connection = TimekeepingDatabaseReset.connect(timekeeping_url, name)
    raise PG::ConnectionBad, "the Timekeeping database #{name.inspect} does not exist", cause: nil unless connection

    digest_groups(GROUPS.fetch(:timekeeping)) do |table|
      connection.exec_params(row_query(table, connection.quote_ident(table.table)), [company_id]).column_values(0)
    end
  ensure
    connection&.close
  end

  # tables is [[table_name, [row_text, ...]], ...]. Each table name and each
  # row is framed with a tag and its byte length, so a row moved to the next
  # table, or one row split in two, never feeds the hash the same bytes.
  def group_digest(tables)
    tables.each_with_object(Digest::SHA256.new) do |(table, rows), sha|
      sha << frame(TABLE_FRAME, table)
      rows.each { |row| sha << frame(ROW_FRAME, row) }
    end.hexdigest
  end

  def digest_groups(groups)
    groups.transform_values do |tables|
      group_digest(tables.map { |table| [table.table, yield(table)] })
    end
  end

  def row_query(table, quoted_name)
    "SELECT row_to_json(t)::text FROM #{quoted_name} t WHERE #{table.predicate} ORDER BY #{table.order}"
  end

  def frame(tag, text)
    "#{tag}#{text.bytesize}:#{text}"
  end
  private_class_method :require_test_database!, :digest_groups, :row_query, :frame
end
