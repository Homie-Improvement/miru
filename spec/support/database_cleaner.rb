# frozen_string_literal: true

# Cleanup steps for examples whose rows are committed, so a second connection,
# thread or process can see them. These deletes span every company, so they
# belong to the test database only.
module TestDatabaseCleanup
  module_function

  # Empties every table the way the system branch does. Deletion empties the
  # ownership table too, so its one row is put back.
  def delete_all_committed!
    DatabaseCleaner.clean_with :deletion, except: %w(ar_internal_metadata schema_migrations), pre_count: true, reset_ids: false
    TimekeepingOwnership.ensure_initial!
  end

  # Intents and outbox items can be committed on a connection other than the
  # example's, so rolling back the example's transaction leaves them behind.
  # The deletes run on a connection outside the pool: this step runs while the
  # example's stubs are still active, and some examples stub
  # ActiveRecord::Base.connection or methods on a pooled connection.
  def delete_operation_ledger_rows!
    ledger_cleanup_connection.execute("DELETE FROM invoice_operation_outbox_items")
    ledger_cleanup_connection.execute("DELETE FROM invoice_operation_intents")
  end

  def ledger_cleanup_connection
    @ledger_cleanup_connection ||= begin
      db_config = ActiveRecord::Base.connection_pool.db_config
      db_config.adapter_class.new(db_config.configuration_hash)
    end
  end

  # System, committed_data and without_transaction examples run with no
  # enclosing transaction.
  def committed?(metadata)
    metadata[:type] == :system || metadata[:committed_data] || metadata[:without_transaction]
  end
end

RSpec.configure do |config|
  config.before(:suite) do
    DatabaseCleaner.allow_remote_database_url = true
    DatabaseCleaner.url_allowlist = [ENV["DATABASE_URL"]]
    DatabaseCleaner.clean_with :truncation, except: %w(ar_internal_metadata)
    # Truncation empties the ownership table; restore its one row.
    TimekeepingOwnership.ensure_initial!
  end

  config.before do
    DatabaseCleaner.strategy = :transaction
  end

  config.before do
    DatabaseCleaner.start unless TestDatabaseCleanup.committed?(RSpec.current_example.metadata)
  end

  config.append_after do
    DatabaseCleaner.clean unless TestDatabaseCleanup.committed?(RSpec.current_example.metadata)
  end

  config.before(:each, type: :system) do
    TestDatabaseCleanup.delete_all_committed!
  end

  config.before(:each, committed_data: true) do
    TestDatabaseCleanup.delete_all_committed!
  end

  # Also after: a committed row left here would reach the next example,
  # whatever order the suite runs in.
  config.append_after(:each, committed_data: true) do
    TestDatabaseCleanup.delete_all_committed!
  end

  config.append_after(:each, type: :system) do
    Capybara.reset_sessions!
  end

  # Examples tagged :without_transaction run outside the per-example
  # transaction, so a transaction, isolation level or lock the code under test
  # opens is real rather than a savepoint. They start and end with every table
  # truncated and every id sequence restarted.
  config.before(:each, :without_transaction) do
    DatabaseCleaner.clean_with :truncation, except: %w(ar_internal_metadata schema_migrations)
    TimekeepingOwnership.ensure_initial!
  end

  config.append_after(:each, :without_transaction) do
    DatabaseCleaner.clean_with :truncation, except: %w(ar_internal_metadata schema_migrations)
    TimekeepingOwnership.ensure_initial!
  end

  # Declared last so it runs after DatabaseCleaner.clean.
  config.append_after do
    TestDatabaseCleanup.delete_operation_ledger_rows!
  end
end
