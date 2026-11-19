# frozen_string_literal: true

# Run by spec/meta/timekeeping_queue_ledger_spec.rb in its own rspec process,
# with TIMEKEEPING_QUEUE_LEDGER_PATH naming a temporary ledger file. Its name
# does not end in _spec.rb, so a normal suite run never loads it.
#
# These examples finish, claim and fail default-queue jobs on purpose. In the
# parent run, an earlier live runtime may have left the suite's queue ledger
# active, and every reset there records such rows as a stray worker's
# executions. Here each example uses a private ledger session, this process
# never activates the suite's ledger, and the ordinary :without_transaction
# reset removes the rows.
require "rails_helper"
require "securerandom"
require "tmpdir"

RSpec.describe TimekeepingQueueLedger::Session, :without_transaction do
  # "In each window between resets it enqueues one `default` and one `billing_sync` control job. Before the reset it checks that both still exist and have not run."
  it "a default control that finishes between resets fails finish! even when no collector reports it" do
    Dir.mktmpdir("queue-ledger-control-ran") do |dir|
      session = described_class.new(path: File.join(dir, "queue_ledger.json"),
                                    collectors: { "monolith" => -> { [] }, "timekeeping" => -> { [] } },
                                    live: -> { false })
      session.activate!(env: ENV.to_h)
      session.open_window!
      SolidQueue::Job.where(queue_name: "default", class_name: "UpdateInvoiceStatusToOverdueJob")
                     .update_all(finished_at: Time.current)
      session.before_reset!

      expect { session.finish! }.to raise_error(StandardError, /control/i)
    end
  end

  # "Before the reset it checks that both still exist and have not run."
  # "A missing control or an unparsable tmp/timekeeping-integration/queue_ledger.json fails the suite"
  it "a control seen unrun at stop and deleted before the reset still fails finish! as missing" do
    Dir.mktmpdir("queue-ledger-control-missing") do |dir|
      session = described_class.new(path: File.join(dir, "queue_ledger.json"),
                                    collectors: { "monolith" => -> { [] }, "timekeeping" => -> { [] } },
                                    live: -> { false })
      session.activate!(env: ENV.to_h)
      session.open_window!
      session.observe_controls!
      SolidQueue::Job.where(queue_name: "default", class_name: "UpdateInvoiceStatusToOverdueJob").delete_all
      session.before_reset!

      expect { session.finish! }.to raise_error(StandardError, /missing/i)
    end
  end

  # "A job enqueued by other code never stands in for a control."
  it "another code's unrun default job does not stand in for a deleted default control at the reset check" do
    Dir.mktmpdir("queue-ledger-stand-in") do |dir|
      session = described_class.new(path: File.join(dir, "queue_ledger.json"),
                                    collectors: { "monolith" => -> { [] }, "timekeeping" => -> { [] } },
                                    live: -> { false })
      session.activate!(env: ENV.to_h)
      session.open_window!
      SolidQueue::Job.where(queue_name: "default", class_name: "UpdateInvoiceStatusToOverdueJob").delete_all
      ActiveJob::QueueAdapters::SolidQueueAdapter.new.enqueue(UpdateInvoiceStatusToOverdueJob.new)
      session.before_reset!

      expect { session.finish! }.to raise_error(StandardError, /missing/i)
    end
  end

  # "Use `ActiveJob::QueueAdapters::SolidQueueAdapter.new.enqueue`, with `UpdateInvoiceStatusToOverdueJob` on `default` and `SyncStripeSubscriptionCompanyJob` on `billing_sync`."
  it "open_window! inside a transaction that is rolled back leaves both controls committed and visible elsewhere" do
    Dir.mktmpdir("queue-ledger-open-window-rollback") do |dir|
      path = File.join(dir, "queue_ledger.json")
      session = described_class.new(path:, collectors: {}, live: -> { false })
      session.activate!(env: {})
      ActiveRecord::Base.transaction do
        session.open_window!
        raise ActiveRecord::Rollback
      end

      other = SolidQueue::Record.connection_pool.db_config.new_connection
      begin
        classes = other.select_values(<<~SQL)
          SELECT class_name FROM solid_queue_jobs
          WHERE class_name IN ('UpdateInvoiceStatusToOverdueJob', 'SyncStripeSubscriptionCompanyJob')
        SQL
      ensure
        other.disconnect!
      end
      expect(classes).to contain_exactly("UpdateInvoiceStatusToOverdueJob", "SyncStripeSubscriptionCompanyJob")

      session.before_reset!
      expect(TimekeepingQueueLedger.parse(File.read(path))[:controls].map(&:status)).to eq(%w[unrun unrun])
    end
  end

  it "open_window! commits one default and one billing_sync control that a clean reset records as unrun" do
    Dir.mktmpdir("queue-ledger-open-window") do |dir|
      path = File.join(dir, "queue_ledger.json")
      session = described_class.new(path:, collectors: {}, live: -> { false })
      session.activate!(env: {})
      session.open_window!

      jobs = SolidQueue::Job.where(class_name: %w[UpdateInvoiceStatusToOverdueJob SyncStripeSubscriptionCompanyJob])
      expect(jobs.pluck(:class_name, :queue_name)).to contain_exactly(
        %w[UpdateInvoiceStatusToOverdueJob default], %w[SyncStripeSubscriptionCompanyJob billing_sync]
      )

      session.before_reset!
      controls = TimekeepingQueueLedger.parse(File.read(path))[:controls]
      expect(controls.map(&:status)).to eq(%w[unrun unrun])
      expect(controls.map(&:active_job_id)).to match_array(jobs.pluck(:active_job_id))
      expect { session.finish! }.not_to raise_error
    end
  end

  # "Before the reset it checks that both still exist and have not run."
  it "a billing_sync control with a claimed execution and a default control with a failed execution both check as ran" do
    Dir.mktmpdir("queue-ledger-claimed-failed") do |dir|
      path = File.join(dir, "queue_ledger.json")
      session = described_class.new(path:, collectors: {}, live: -> { false })
      session.activate!(env: {})
      session.open_window!
      default_job = SolidQueue::Job.find_by!(class_name: "UpdateInvoiceStatusToOverdueJob")
      billing_job = SolidQueue::Job.find_by!(class_name: "SyncStripeSubscriptionCompanyJob")
      process = SolidQueue::Process.create!(kind: "Worker", last_heartbeat_at: Time.current, pid: Process.pid,
                                            hostname: "queue-ledger-spec", name: "queue-ledger-spec-#{Process.pid}")
      SolidQueue::ReadyExecution.where(job_id: billing_job.id).delete_all
      SolidQueue::ClaimedExecution.create!(job_id: billing_job.id, process_id: process.id)
      SolidQueue::ReadyExecution.where(job_id: default_job.id).delete_all
      SolidQueue::FailedExecution.create!(job_id: default_job.id, error: { "message" => "boom" })

      session.before_reset!

      controls = TimekeepingQueueLedger.parse(File.read(path))[:controls]
      expect(controls.map(&:status)).to eq(%w[ran ran])
    end
  end
end

RSpec.describe TimekeepingQueueLedger::MonolithCollector, :without_transaction do
  # "it collects claimed, completed and failed Solid Queue executions on any queue other than the dedicated ones"
  it "returns a finished default job and ignores a ready one" do
    adapter = ActiveJob::QueueAdapters::SolidQueueAdapter.new
    finished = UpdateInvoiceStatusToOverdueJob.new
    ready = UpdateInvoiceStatusToOverdueJob.new
    adapter.enqueue(finished)
    adapter.enqueue(ready)
    SolidQueue::Job.find_by!(active_job_id: finished.job_id).update!(finished_at: Time.current)

    records = described_class.collect

    expect(records.map(&:active_job_id)).to eq([finished.job_id])
    expect(records.first).to have_attributes(database: "monolith", queue: "default", kind: "completed")
  end
end
