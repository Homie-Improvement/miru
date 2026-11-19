# frozen_string_literal: true

# Run by spec/timekeeping/timekeeping_collector_rows_spec.rb in its own rspec
# process, with TIMEKEEPING_QUEUE_LEDGER_PATH naming a temporary ledger file.
# The invoice_operations rows written here break the Timekeeping queue rule on
# purpose, so they must never reach a suite ledger that another run activated.
require "rails_helper"
require "pg"
require "securerandom"
require "open3"

RSpec.describe TimekeepingQueueLedger::TimekeepingCollector, :without_transaction do
  # "A database-backed spec creates completed, claimed and failed Timekeeping Solid Queue jobs, calls
  # TimekeepingCollector.collect, and asserts their identities and kinds, with invoice_operations collected and
  # timekeeping_relay ignored."
  it "collects completed, claimed and failed invoice_operations jobs from the Timekeeping database and ignores timekeeping_relay jobs in every state" do
    skip "set TIMEKEEPING_LIVE=1 to use the Timekeeping test database" unless ENV["TIMEKEEPING_LIVE"] == "1"

    url = ENV.fetch("TIMEKEEPING_DATABASE_URL")
    env = { "TIMEKEEPING_DATABASE_URL" => url }
    IntegratedRuntime.require_test_database_url!(url)
    output, status = Bundler.with_unbundled_env do
      Open3.capture2e({ "RAILS_ENV" => "test", "BUNDLE_GEMFILE" => Rails.root.join("timekeeping/Gemfile").to_s,
                        "TIMEKEEPING_DATABASE_URL" => url, "DATABASE_URL" => nil },
                      "bundle", "exec", "rails", "db:prepare", chdir: Rails.root.join("timekeeping").to_s)
    end
    expect(status).to be_success, output
    TimekeepingDatabaseReset.reset!(nil, env:)

    connection = PG.connect(url)
    begin
      insert_job = lambda do |queue, class_name, finished|
        active_job_id = SecureRandom.uuid
        id = connection.exec_params(<<~SQL, [queue, class_name, active_job_id, finished]).getvalue(0, 0)
          INSERT INTO solid_queue_jobs (queue_name, class_name, active_job_id, finished_at, created_at, updated_at)
          VALUES ($1, $2, $3, CASE WHEN $4::boolean THEN now() END, now(), now()) RETURNING id
        SQL
        [Integer(id, 10), active_job_id]
      end
      process_id = connection.exec_params(<<~SQL, [Process.pid, "collector-rows-probe-#{SecureRandom.hex(4)}"]).getvalue(0, 0)
        INSERT INTO solid_queue_processes (kind, last_heartbeat_at, pid, name, created_at)
        VALUES ('Worker', now(), $1, $2, now()) RETURNING id
      SQL
      claim = lambda do |job_id|
        Integer(connection.exec_params(<<~SQL, [job_id, process_id]).getvalue(0, 0), 10)
          INSERT INTO solid_queue_claimed_executions (job_id, process_id, created_at) VALUES ($1, $2, now()) RETURNING id
        SQL
      end
      fail_job = lambda do |job_id|
        Integer(connection.exec_params(<<~SQL, [job_id, "probe failure"]).getvalue(0, 0), 10)
          INSERT INTO solid_queue_failed_executions (job_id, error, created_at) VALUES ($1, $2, now()) RETURNING id
        SQL
      end

      forbidden_class = "RecoverInvoiceOperationIntentsJob"
      completed_id, completed_active_id = insert_job.call("invoice_operations", forbidden_class, true)
      claimed_id, claimed_active_id = insert_job.call("invoice_operations", forbidden_class, false)
      claimed_execution_id = claim.call(claimed_id)
      failed_id, failed_active_id = insert_job.call("invoice_operations", forbidden_class, false)
      failed_execution_id = fail_job.call(failed_id)

      insert_job.call("timekeeping_relay", "Timekeeping::RelayJob", true)
      relay_claimed_id, = insert_job.call("timekeeping_relay", "Timekeeping::RelayJob", false)
      claim.call(relay_claimed_id)
      relay_failed_id, = insert_job.call("timekeeping_relay", "Timekeeping::RelayJob", false)
      fail_job.call(relay_failed_id)

      records = described_class.collect(env)

      expect(records).to contain_exactly(
        have_attributes(database: "timekeeping", queue: "invoice_operations", job_class: forbidden_class,
                        kind: "completed", job_id: completed_id, active_job_id: completed_active_id,
                        execution_id: nil),
        have_attributes(database: "timekeeping", queue: "invoice_operations", job_class: forbidden_class,
                        kind: "claimed", job_id: claimed_id, active_job_id: claimed_active_id,
                        execution_id: claimed_execution_id),
        have_attributes(database: "timekeeping", queue: "invoice_operations", job_class: forbidden_class,
                        kind: "failed", job_id: failed_id, active_job_id: failed_active_id,
                        execution_id: failed_execution_id)
      )
      expect(records.map(&:queue)).not_to include("timekeeping_relay")
    ensure
      connection.close
      TimekeepingDatabaseReset.reset!(nil, env:)
    end
  end
end
