# frozen_string_literal: true

# Run by spec/meta/timekeeping_queue_ledger_spec.rb in its own rspec process,
# with INLINE_QUEUE_PROBE naming a scenario and TIMEKEEPING_QUEUE_LEDGER_PATH
# naming a temporary ledger file, so this run's suite start cannot delete the
# parent's ledger. Its name does not end in _spec.rb, so a normal suite run
# never loads it.
#
# The example carries :inline_jobs_on_dedicated_queues and performs one job
# inline, which writes no Solid Queue row; only the tag's hook can judge it:
# - default: a default-queue job runs, so the run fails;
# - skip_after_default: a default-queue job runs and the example then skips,
#   so the run still fails;
# - dedicated: an invoice_operations job runs, so the run passes.
require "rails_helper"

RSpec.describe "Timekeeping inline dedicated queue probe", :inline_jobs_on_dedicated_queues do
  def inline_probe_job(queue)
    Class.new(ApplicationJob) do
      queue_as queue

      def perform; end
    end
  end

  it "performs a job inline for the selected scenario" do
    scenario = ENV.fetch("INLINE_QUEUE_PROBE")

    case scenario
    when "default"
      stub_const("InlineQueueProbeDefaultJob", inline_probe_job(:default)).perform_now
    when "skip_after_default"
      stub_const("InlineQueueProbeDefaultJob", inline_probe_job(:default)).perform_now
      skip "skipped after the default-queue job already ran"
    when "dedicated"
      stub_const("InlineQueueProbeOperationsJob", inline_probe_job(:invoice_operations)).perform_now
    else
      raise ArgumentError, "INLINE_QUEUE_PROBE must be default, skip_after_default or dedicated"
    end
  end
end
