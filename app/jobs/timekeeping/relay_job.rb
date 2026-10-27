# frozen_string_literal: true

module Timekeeping
  # Delivers the prepared monolith's local entry outbox (entry_outbox_items) to
  # this application's own projection endpoint, so writes made after a rollback
  # reach timesheet_entries and the time report with no Timekeeping process
  # running (docs/architecture/timekeeping-soa.md section 10.1). The recurring
  # task in config/solid_queue.yml enqueues it, and only the timekeeping_relay
  # worker runs it. It takes no arguments: the URL and token are read from the
  # environment when the endpoint is built, so nothing secret is stored with
  # the enqueued job.
  class RelayJob < ApplicationJob
    queue_as :timekeeping_relay

    # The most rows one POST carries.
    BATCH_SIZE = 100
    # Held for the whole run. Two runs at once could each read the same unsent
    # rows and send a later batch before an earlier one, so a run that cannot
    # take the lock leaves delivery to the run that holds it. It differs from
    # LocalOwner::OUTBOX_LOCK_KEY, so entry writes never wait on a delivery, and
    # from the Timekeeping service relay's key.
    RELAY_LOCK_KEY = 2_026_034_003

    # One relay per company: a batch then never mixes companies, and the
    # projection's refusal of a whole batch stops only that company's delivery.
    def perform
      with_relay_lock do
        endpoint = LocalSnapshotEndpoint.configured
        Company.order(:id).pluck(:id).each do |company_id|
          TimekeepingRelay::Relay.new(source: LocalOutboxSource.new(company_id:), endpoint:)
                                 .deliver(limit: BATCH_SIZE)
        end
      end
    end

    private

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
end
