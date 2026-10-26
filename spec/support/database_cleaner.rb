# frozen_string_literal: true

RSpec.configure do |config|
  # Examples tagged :without_transaction run outside the per-example
  # transaction, so a transaction, isolation level or lock the code under test
  # opens is real rather than a savepoint. They start and end with every table
  # truncated and every id sequence restarted.
  # System specs and committed_data examples (spec/support/committed_data.rb)
  # also need their writes committed, so they clean up by deletion instead.
  outside_transaction = ->(example) {
    example.metadata[:type] == :system ||
      example.metadata[:without_transaction] ||
      CommittedDataMode.example?(example)
  }

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

  config.before do |example|
    DatabaseCleaner.start unless outside_transaction.call(example)
  end

  config.append_after do |example|
    DatabaseCleaner.clean unless outside_transaction.call(example)
  end

  config.before(:each, type: :system) do
    DatabaseCleaner.clean_with :deletion, except: %w(ar_internal_metadata schema_migrations), pre_count: true, reset_ids: false
    TimekeepingOwnership.ensure_initial!
  end

  config.append_after(:each, type: :system) do
    Capybara.reset_sessions!
  end

  config.before(:each, :without_transaction) do
    DatabaseCleaner.clean_with :truncation, except: %w(ar_internal_metadata schema_migrations)
    TimekeepingOwnership.ensure_initial!
  end

  config.append_after(:each, :without_transaction) do
    DatabaseCleaner.clean_with :truncation, except: %w(ar_internal_metadata schema_migrations)
    TimekeepingOwnership.ensure_initial!
  end
end
