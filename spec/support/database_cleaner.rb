# frozen_string_literal: true

# Cleanup steps for examples whose rows are committed, so a second connection,
# thread or process can see them. These deletes span every company, so they
# belong to the test database only.
module TestDatabaseCleanup
  KEPT_TABLES = %w[ar_internal_metadata schema_migrations].freeze

  module_function

  # Empties every table the way the system branch does. Deletion empties the
  # ownership table too, so its one row is put back.
  def delete_all_committed!
    delete_all_tables!
    TimekeepingOwnership.ensure_initial!
  end

  # A committed example in a :two_tenant_seed group needs the seed reloaded
  # after the committed cleanup, which would otherwise delete it.
  def seeded_committed?(metadata)
    metadata[:committed_data] == true && metadata[:two_tenant_seed] ? true : false
  end

  # The as_of the checked-in seed disposition was recorded with, so the loaded
  # seed matches that record.
  def seed_as_of
    YAML.load_file(Timekeeping::SeedDispositionRecorder::DEFAULT_PATH).fetch("as_of")
  end

  # Empties every table, loads the seed, then puts the ownership row in the
  # selected state and clears the Timekeeping database.
  #
  # The order matters. load_fresh_seed! refuses any occupied table, the
  # ownership table included, so ensure_initial! must not run before it.
  # db/seeds.rb refuses to load once a handoff has begun, so a non-legacy
  # state is applied only after the seed is in.
  #
  # state nil means no state is selected: the row ensure_initial! writes is
  # already the legacy default, and apply! rejects nil.
  def reset_seeded_committed!(as_of:, state: TimekeepingOwnerState::SELECTED, env: ENV)
    delete_all_tables!
    Timekeeping::SeedDispositionRecorder.load_fresh_seed!(as_of:)
    TimekeepingOwnership.ensure_initial!
    TimekeepingOwnerState.apply!(state) if state
    TimekeepingDatabaseReset.reset!(state, env:)
  end

  # clean_with! calls this before it deletes anything. It does nothing
  # unless an integrated runtime has activated the queue ledger
  # (spec/support/timekeeping/queue_ledger.rb); then it records the Solid
  # Queue executions the reset would otherwise erase unobserved.
  def before_reset!
    TimekeepingQueueLedger.session.before_reset!
  end

  # The one way to empty monolith tables: it records the queue executions
  # first, so no reset can erase them without a record. The strategy and
  # options go to DatabaseCleaner unchanged, because each reset keeps its own
  # list of tables.
  def clean_with!(strategy, **options)
    before_reset!
    DatabaseCleaner.clean_with(strategy, **options)
  end

  def delete_all_tables!
    clean_with!(:deletion, except: KEPT_TABLES, pre_count: true, reset_ids: false)
  end
  private_class_method :delete_all_tables!

  # Intents and outbox items can be committed on a connection other than the
  # example's, so rolling back the example's transaction leaves them behind.
  def delete_operation_ledger_rows!
    connection = ActiveRecord::Base.connection
    connection.execute("DELETE FROM invoice_operation_outbox_items")
    connection.execute("DELETE FROM invoice_operation_intents")
  end

  # System, committed_data (spec/support/committed_data.rb) and
  # without_transaction examples run with no enclosing transaction, so their
  # writes really commit.
  #
  # Examples tagged :seeded_without_transaction, used with :two_tenant_seed,
  # also run outside that transaction but are not truncated, so the seed the
  # group loaded once survives between its examples. The group's own
  # truncation cleans up when it finishes; an example that writes rows needs
  # a group of its own.
  #
  # Examples tagged :integrated_runtime run beside a started demo runtime whose
  # processes read rows over their own connections, so nothing may stay
  # uncommitted; spec/support/timekeeping/integrated_runtime.rb cleans for them.
  def committed?(example)
    example.metadata[:integrated_runtime] ||
      example.metadata[:type] == :system ||
      example.metadata[:without_transaction] ||
      example.metadata[:seeded_without_transaction] ||
      CommittedDataMode.example?(example)
  end

  # An :integrated_runtime example may reset the databases only once it has
  # confirmed no earlier runtime is live, and only after its own runtime
  # stopped (spec/support/timekeeping/integrated_runtime.rb sets the flag).
  # Otherwise a surviving runtime's workers could be writing during a reset.
  def reset_withheld?(example)
    example.metadata[:integrated_runtime] && !example.metadata[:integrated_runtime_resets_allowed]
  end
end

RSpec.configure do |config|
  config.before(:suite) do
    DatabaseCleaner.allow_remote_database_url = true
    DatabaseCleaner.url_allowlist = [ENV["DATABASE_URL"]]
    TestDatabaseCleanup.clean_with!(:truncation, except: %w(ar_internal_metadata))
    # Truncation empties the ownership table; restore its one row.
    TimekeepingOwnership.ensure_initial!
  end

  config.before do
    DatabaseCleaner.strategy = :transaction
  end

  config.before do |example|
    DatabaseCleaner.start unless TestDatabaseCleanup.committed?(example)
  end

  config.append_after do |example|
    DatabaseCleaner.clean unless TestDatabaseCleanup.committed?(example)
  end

  config.before(:each, type: :system) do
    TestDatabaseCleanup.delete_all_committed!
  end

  # Before as well as after (the after step is in spec/support/committed_data.rb):
  # a tagged example starts from committed-empty tables whatever ran before it,
  # or, when it is also tagged :two_tenant_seed, from a freshly loaded seed.
  config.before(:each, committed_data: true) do |example|
    if TestDatabaseCleanup.seeded_committed?(example.metadata)
      TestDatabaseCleanup.reset_seeded_committed!(as_of: TestDatabaseCleanup.seed_as_of)
    else
      TestDatabaseCleanup.delete_all_committed!
    end
  end

  config.append_after(:each, type: :system) do
    Capybara.reset_sessions!
  end

  # Examples tagged :without_transaction run outside the per-example
  # transaction, so a transaction, isolation level or lock the code under test
  # opens is real rather than a savepoint. They start and end with every table
  # truncated and every id sequence restarted.
  #
  # This hook runs after the committed_data one, so it skips a seeded
  # committed example: truncating here would delete the seed just loaded.
  config.before(:each, :without_transaction) do |example|
    next if TestDatabaseCleanup.seeded_committed?(example.metadata)

    TestDatabaseCleanup.clean_with!(:truncation, except: %w(ar_internal_metadata schema_migrations))
    TimekeepingOwnership.ensure_initial!
  end

  config.append_after(:each, :without_transaction) do |example|
    next if TestDatabaseCleanup.reset_withheld?(example)

    TestDatabaseCleanup.clean_with!(:truncation, except: %w(ar_internal_metadata schema_migrations))
    TimekeepingOwnership.ensure_initial!
  end

  # Declared last so it runs after DatabaseCleaner.clean.
  config.append_after do |example|
    next if TestDatabaseCleanup.reset_withheld?(example)

    TestDatabaseCleanup.delete_operation_ledger_rows!
  end
end
