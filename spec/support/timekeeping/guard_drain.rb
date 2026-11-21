# frozen_string_literal: true

# Waits the live single-writer guard
# (spec/integration/timekeeping/single_writer_guard_spec.rb) runs before it
# reads the writer log. Projection rows arrive from the runtime's own workers,
# on other database sessions, so a case's measured window may close only once
# every write the case caused has landed; otherwise a late write is wiped by
# the next case's clear! or blamed on the wrong case.
#
# Every wait is bounded on the monotonic clock and raises naming the case and
# what it waited for, so a stuck worker fails the example instead of hanging
# it or letting the window close early.
module TimekeepingGuardDrain
  class Timeout < StandardError; end
  class Undeliverable < StandardError; end

  DEFAULT_WITHIN_SECONDS = 60
  POLL_INTERVAL_SECONDS = 0.1

  module_function

  # Calls the block until it returns a truthy value, and returns that value.
  def poll_until(case_name:, awaiting:, within: DEFAULT_WITHIN_SECONDS)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
    loop do
      observed = yield
      return observed if observed

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        raise Timeout, "#{case_name}: #{awaiting} not reached within #{within} s"
      end

      sleep POLL_INTERVAL_SECONDS
    end
  end

  # Waits until no invoice operation intent is pending and every commit or
  # abort in the outbox has been delivered. An undeliverable item will never
  # be delivered, so it fails at once rather than at the deadline.
  def invoice_operations_settled!(case_name:, within: DEFAULT_WITHIN_SECONDS)
    poll_until(case_name:, awaiting: "invoice operations settled", within:) do
      undeliverable = InvoiceOperationOutboxItem.uncached do
        InvoiceOperationOutboxItem.where.not(undeliverable_at: nil).pluck(:id)
      end
      if undeliverable.any?
        raise Undeliverable, "#{case_name}: invoice operation outbox items #{undeliverable.inspect} are undeliverable"
      end

      InvoiceOperationIntent.uncached do
        InvoiceOperationIntent.where(state: "pending").none? &&
          InvoiceOperationOutboxItem.where(delivered_at: nil).none?
      end
    end
  end

  # Waits until every projection row in expected reads as expected.
  # expected maps an entry id to the attributes its row must hold, as a hash
  # such as { "bill_status" => "billed" }. An empty attributes hash only
  # requires the row to exist.
  def entries_settled!(case_name:, expected:, within: DEFAULT_WITHIN_SECONDS)
    poll_until(case_name:, awaiting: "entries #{expected.keys.inspect} in their expected state", within:) do
      rows = TimesheetEntry.uncached { TimesheetEntry.unscoped.where(id: expected.keys).index_by(&:id) }
      expected.all? { |entry_id, state| entry_matches?(rows[entry_id], state) }
    end
  end

  # Waits until the Timekeeping service has sent every outbox snapshot it
  # held when the wait began. store is a Timekeeping::Handoff::TimekeepingStore.
  # drain answers false whenever the runtime's own relay worker holds the
  # relay lock, even after that worker has sent every row, so a false answer
  # is checked against the unsent positions in the Timekeeping database, the
  # same rule TimekeepingLiveHandoff.catch_up! applies.
  def timekeeping_outbox_drained!(case_name:, store:, within: DEFAULT_WITHIN_SECONDS)
    through = store.highest_outbox_position
    awaiting = "Timekeeping outbox drained through #{through} " \
               "(a false drain answer can mean the relay worker held the relay lock)"
    poll_until(case_name:, awaiting:, within:) do
      store.drain(through:) || timekeeping_unsent_positions(through).empty?
    end
  end

  def timekeeping_unsent_positions(through)
    TimekeepingLiveHandoff.with_timekeeping_database do |connection|
      TimekeepingLiveHandoff.unsent_outbox_positions(connection, through:)
    end
  end
  private_class_method :timekeeping_unsent_positions

  # Waits until the prepared monolith's relay worker has sent every entry
  # snapshot in its outbox.
  def local_outbox_drained!(case_name:, within: DEFAULT_WITHIN_SECONDS)
    poll_until(case_name:, awaiting: "monolith entry outbox drained", within:) do
      Timekeeping::LocalOutboxEntry.uncached { Timekeeping::LocalOutboxEntry.where(sent_at: nil).none? }
    end
  end

  def entry_matches?(row, state)
    !row.nil? && state.all? { |attribute, value| row.public_send(attribute) == value }
  end
  private_class_method :entry_matches?
end
