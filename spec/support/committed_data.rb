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
    BLOCKER_POLL_INTERVAL = 0.02

    # Runs the block on a new thread with its own database connection, which
    # it returns to the pool when the block ends. When backend_pids is given,
    # the thread first pushes that connection's server process id to it, so a
    # lock check can name the exact session that runs the block's statement.
    def committed_data_thread(backend_pids = nil, &block)
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          backend_pids&.push(connection.select_value("SELECT pg_backend_pid()"))
          block.call
        end
      end
    end

    # True once the server reports waiting_pid blocked by holding_pid's locks;
    # false when that has not happened within the given seconds. A thread that
    # is alive but has not yet sent its statement is not blocked, which a
    # timed Thread#join cannot tell apart from a real lock wait.
    #
    # The check runs on a connection opened outside the pool: the holder and
    # contender threads can lease every pooled connection, and the check must
    # not wait for one of them to finish.
    def blocked_by?(waiting_pid, holding_pid, within: 3)
      observer = ActiveRecord::Base.connection_pool.db_config.new_connection
      query = "SELECT #{observer.quote(holding_pid)} = ANY(pg_blocking_pids(#{observer.quote(waiting_pid)}))"
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        return true if observer.select_value(query)

        sleep BLOCKER_POLL_INTERVAL
      end
      false
    ensure
      observer&.disconnect!
    end
  end
end

RSpec.configure do |config|
  config.include CommittedDataMode::Helpers, committed_data: true

  config.append_after(:each, committed_data: true) do
    CommittedDataMode.reset_database
  end
end
