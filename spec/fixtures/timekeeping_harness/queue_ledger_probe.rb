# frozen_string_literal: true

# Run by spec/meta/timekeeping_queue_ledger_spec.rb in its own rspec process,
# with QUEUE_LEDGER_PROBE naming a scenario and TIMEKEEPING_QUEUE_LEDGER_PATH
# naming a temporary ledger file. Its name does not end in _spec.rb, so a
# normal suite run never loads it.
#
# The example activates the queue ledger the way the integrated runtime does,
# without starting one, then changes Solid Queue rows. The :without_transaction
# reset after the example checks and records them, and the ledger's
# after(:suite) hook decides the exit status:
# - clean: the controls stay unrun, so the run passes;
# - control_ran: the default control is marked finished, so the run fails;
# - non_dedicated: another job on the default queue completes, so the run fails.
require "rails_helper"

RSpec.describe "Timekeeping queue ledger probe", :without_transaction do
  def mark_finished(scope)
    scope.find_by!(queue_name: "default", class_name: "UpdateInvoiceStatusToOverdueJob").update!(finished_at: Time.current)
  end

  it "changes Solid Queue rows for the selected scenario" do
    scenario = ENV.fetch("QUEUE_LEDGER_PROBE")
    ledger = TimekeepingQueueLedger.session
    ledger.activate!(env: ENV.to_h)

    case scenario
    when "clean"
      ledger.open_window!
    when "control_ran"
      ledger.open_window!
      mark_finished(SolidQueue::Job)
    when "non_dedicated"
      ActiveJob::QueueAdapters::SolidQueueAdapter.new.enqueue(UpdateInvoiceStatusToOverdueJob.new)
      mark_finished(SolidQueue::Job)
    else
      raise ArgumentError, "QUEUE_LEDGER_PROBE must be clean, control_ran or non_dedicated"
    end

    expect(ledger.active?).to be(true)
  end
end
