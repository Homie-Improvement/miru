# frozen_string_literal: true

# Examples tagged `committed_data: true` run without the per-example cleaner
# transaction, so their writes really commit and a second database connection
# can see them. That is the only way to prove lock behaviour between two
# transactions: one connection never waits on its own locks.
#
# Committed rows survive the transactional cleaner, so after each such example
# every table is emptied and the ownership row is put back with its column
# defaults (no handoff step). Without that, a handoff_step left set by one
# example would refuse the billing writes of every later example.
module CommittedDataMode
  KEPT_TABLES = %w[ar_internal_metadata schema_migrations].freeze

  def self.example?(example)
    example.metadata[:committed_data] == true
  end

  def self.reset_database
    DatabaseCleaner.clean_with(:deletion, except: KEPT_TABLES)
    TimekeepingOwnership.ensure_initial!
  end

  module Helpers
    # Runs the block on a new thread with its own database connection, which
    # it returns to the pool when the block ends.
    def committed_data_thread(&block)
      Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }
    end
  end
end

RSpec.configure do |config|
  config.include CommittedDataMode::Helpers, committed_data: true

  config.append_after(:each, committed_data: true) do
    CommittedDataMode.reset_database
  end
end
