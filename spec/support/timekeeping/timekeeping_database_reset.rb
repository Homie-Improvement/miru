# frozen_string_literal: true

require "pg"

# Refuses to touch a database unless its name marks it as a test database.
# Every CI database in .github/workflows/validations.yml ends in "_test".
module TestDatabaseGuard
  TEST_DATABASE_SUFFIX = "_test"

  # The message names only the database, never the URL it came from, because
  # the URL can carry a password into CI logs.
  class NotATestDatabase < StandardError
    def initialize(name)
      super("Refusing to empty database #{name.inspect}: its name does not end in #{TEST_DATABASE_SUFFIX.inspect}")
    end
  end

  module_function

  def require_test_database!(name)
    raise NotATestDatabase, name unless name.is_a?(String) && name.end_with?(TEST_DATABASE_SUFFIX)

    nil
  end
end

# Empties the Timekeeping database named by TIMEKEEPING_DATABASE_URL and puts
# back its admission row at the generation the owner state requires. A missing
# admission row refuses every entry write, so the row is always inserted.
#
# timekeeping/config/database.yml reads that URL in every environment, so a
# developer who kept a demo URL would lose real rows: the database name is
# checked before any connection is opened.
module TimekeepingDatabaseReset
  DATABASE_URL_KEY = "TIMEKEEPING_DATABASE_URL"
  KEPT_TABLES = %w[ar_internal_metadata schema_migrations].freeze
  # The only id the Timekeeping admission table allows
  # (timekeeping/app/models/timekeeping/admission.rb), which the monolith does not load.
  ADMISSION_ID = 1

  module_function

  # state_name nil means no owner state is selected; the admission row then
  # takes its column default, as it does for legacy.
  def reset!(state_name, env:)
    return nil unless env.key?(DATABASE_URL_KEY)

    generation = admission_generation(state_name)
    url = env.fetch(DATABASE_URL_KEY)
    TestDatabaseGuard.require_test_database!(database_name(url))
    connection = connect(url)
    return nil unless connection

    connection.transaction do
      truncate_tables(connection)
      insert_admission(connection, state_name, generation)
    end
    nil
  ensure
    connection&.close
  end

  def admission_generation(state_name)
    return nil if state_name.nil?

    TimekeepingOwnerState.fetch(state_name).fetch(:admission_generation)
  end

  # Reads the name from URL or keyword form. A value libpq cannot parse yields
  # no name, so the guard refuses it without echoing the value back.
  def database_name(url)
    PG::Connection.conninfo_parse(url).find { |option| option[:keyword] == "dbname" }&.fetch(:val)
  rescue PG::Error
    nil
  end

  # nil when the database does not exist yet, so there is nothing to empty.
  def connect(url)
    PG.connect(url)
  rescue PG::ConnectionBad
    nil
  end

  # One statement, so foreign keys between the tables need no ordering.
  def truncate_tables(connection)
    tables = connection.exec("SELECT tablename FROM pg_tables WHERE schemaname = 'public'")
                       .column_values(0) - KEPT_TABLES
    return if tables.empty?

    connection.exec("TRUNCATE #{tables.map { |table| connection.quote_ident(table) }.join(', ')}")
  end

  # With no state, and for legacy, only the id is inserted so the column
  # default sets the generation. Rollback stores null: the retired Timekeeping
  # owner admits no generation (docs/architecture/timekeeping-soa.md 10.5).
  def insert_admission(connection, state_name, generation)
    if state_name.nil? || state_name == TimekeepingOwnerState::DEFAULT_STATE
      connection.exec_params("INSERT INTO admission (id) VALUES ($1)", [ADMISSION_ID])
    else
      connection.exec_params("INSERT INTO admission (id, generation) VALUES ($1, $2)", [ADMISSION_ID, generation])
    end
  end
  private_class_method :admission_generation, :database_name, :connect, :truncate_tables, :insert_admission
end
