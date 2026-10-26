# frozen_string_literal: true

# Delivers this service's entry snapshot outbox to the monolith's projection
# endpoint (docs/architecture/timekeeping-soa.md section 5.4). The recurring
# task in config/solid_queue.yml enqueues it, and only the timekeeping_relay
# worker runs it.
class RelayJob < ActiveJob::Base
  queue_as :timekeeping_relay

  # The most rows one POST carries.
  BATCH_SIZE = 100
  # Held for the whole run. Two runs at once could each read the same unsent
  # rows and send a later batch before an earlier one, so a run that cannot
  # take the lock leaves delivery to the run that holds it. The worker's single
  # thread does not cover a duplicate enqueue or a perform_now from elsewhere.
  RELAY_LOCK_KEY = 2_026_034_002

  def perform
    with_relay_lock do
      TimekeepingRelay::Relay.new(source: Timekeeping::RelayOutboxSource.new,
                                  endpoint: Timekeeping::SnapshotEndpoint.configured,
                                  paused: relay_pause_check)
                             .deliver(limit: BATCH_SIZE)
    end
  end

  private

    # The pause control exists only where the test hooks are loaded; anywhere
    # else the relay is never paused.
    def relay_pause_check
      return TimekeepingRelay::Relay::NEVER_PAUSED unless defined?(Timekeeping::TestHooks)

      Timekeeping::TestHooks.method(:relay_paused?)
    end

    # A session lock rather than a transaction lock, so no transaction stays
    # open across the POST and each mark_sent commits on its own.
    def with_relay_lock
      connection = ApplicationRecord.connection
      return unless connection.select_value(lock_sql("pg_try_advisory_lock"))

      begin
        yield
      ensure
        connection.select_value(lock_sql("pg_advisory_unlock"))
      end
    end

    def lock_sql(function)
      ApplicationRecord.sanitize_sql_array(["SELECT #{function}(?)", RELAY_LOCK_KEY])
    end
end
