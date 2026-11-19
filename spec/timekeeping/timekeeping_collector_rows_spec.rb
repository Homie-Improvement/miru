# frozen_string_literal: true

require "rails_helper"
require "open3"
require "pg"
require "securerandom"
require "tmpdir"

RSpec.describe "Timekeeping collector real-row examples", :without_transaction do
  # "A database-backed spec creates completed, claimed and failed Timekeeping Solid Queue jobs, calls
  # TimekeepingCollector.collect, and asserts their identities and kinds, with invoice_operations collected and
  # timekeeping_relay ignored."
  it "the Timekeeping collector row probe passes every example in its own run with a private ledger and skips none" do
    skip "set TIMEKEEPING_LIVE=1 to use the Timekeeping test database" unless ENV["TIMEKEEPING_LIVE"] == "1"

    probe = Rails.root.join("spec/fixtures/timekeeping_harness/timekeeping_collector_rows_probe.rb")
    expect(probe).to exist
    expect(probe.basename.to_s).not_to end_with("_spec.rb")

    Dir.mktmpdir("timekeeping-collector-rows") do |dir|
      ledger_path = File.join(dir, "collector_rows_ledger.json")
      stdout, stderr, status = Open3.capture3(
        { TimekeepingQueueLedger::PATH_KEY => ledger_path },
        "bundle", "exec", "rspec", probe.to_s, chdir: Rails.root.to_s
      )

      expect(status).to be_success, "#{stdout}\n#{stderr}"
      summary = stdout[/(\d+) examples?, 0 failures(.*)$/]
      expect(summary).not_to be_nil, stdout
      expect(Integer(Regexp.last_match(1), 10)).to be >= 1
      expect(summary).not_to include("pending")
    end
  end
end

RSpec.describe TimekeepingQueueLedger::TimekeepingCollector do
  # "A database-backed spec creates completed, claimed and failed Timekeeping Solid Queue jobs, calls
  # TimekeepingCollector.collect, and asserts their identities and kinds, with invoice_operations collected and
  # timekeeping_relay ignored."
  it "collects completed, claimed and failed invoice_operations jobs from the Timekeeping database once each and ignores timekeeping_relay jobs" do
    skip "set TIMEKEEPING_LIVE=1 to use the Timekeeping test database" unless ENV["TIMEKEEPING_LIVE"] == "1"

    url = ENV.fetch("TIMEKEEPING_DATABASE_URL")
    IntegratedRuntime.require_test_database_url!(url)
    output, status = Bundler.with_unbundled_env do
      Open3.capture2e({ "RAILS_ENV" => "test", "BUNDLE_GEMFILE" => Rails.root.join("timekeeping/Gemfile").to_s,
                        "TIMEKEEPING_DATABASE_URL" => url, "DATABASE_URL" => nil },
                      "bundle", "exec", "rails", "db:prepare", chdir: Rails.root.join("timekeeping").to_s)
    end
    expect(status).to be_success, output

    connection = PG.connect(url)
    job_ids = []
    process_id = nil
    begin
      insert_id = ->(sql, params) { Integer(connection.exec_params(sql, params).getvalue(0, 0), 10) }
      insert_job = lambda do |queue, finished|
        active_job_id = SecureRandom.uuid
        job_id = insert_id.call(
          "INSERT INTO solid_queue_jobs (queue_name, class_name, active_job_id, finished_at, created_at, updated_at) " \
          "VALUES ($1, $2, $3, $4, now(), now()) RETURNING id",
          [queue, "TimekeepingCollectorRowsJob", active_job_id, finished ? Time.current.utc.iso8601(6) : nil]
        )
        job_ids << job_id
        { job_id:, active_job_id: }
      end
      process_id = insert_id.call(
        "INSERT INTO solid_queue_processes (kind, last_heartbeat_at, pid, name, created_at) " \
        "VALUES ('Worker', now(), $1, $2, now()) RETURNING id",
        [Process.pid, "timekeeping-collector-rows-#{SecureRandom.hex(6)}"]
      )

      jobs_by_queue = %w[invoice_operations timekeeping_relay].to_h do |queue|
        completed = insert_job.call(queue, true)
        claimed = insert_job.call(queue, false)
        claimed_execution_id = insert_id.call(
          "INSERT INTO solid_queue_claimed_executions (job_id, process_id, created_at) VALUES ($1, $2, now()) RETURNING id",
          [claimed[:job_id], process_id]
        )
        failed = insert_job.call(queue, false)
        failed_execution_id = insert_id.call(
          "INSERT INTO solid_queue_failed_executions (job_id, error, created_at) VALUES ($1, $2, now()) RETURNING id",
          [failed[:job_id], "boom"]
        )
        [queue, { completed: completed.merge(execution_id: nil),
                  claimed: claimed.merge(execution_id: claimed_execution_id),
                  failed: failed.merge(execution_id: failed_execution_id) }]
      end
      inserted_active_job_ids = jobs_by_queue.values.flat_map { |jobs| jobs.values.map { |job| job[:active_job_id] } }

      records = described_class.collect({ "TIMEKEEPING_DATABASE_URL" => url })
      ours = records.select { |record| inserted_active_job_ids.include?(record.active_job_id) }

      forbidden = jobs_by_queue.fetch("invoice_operations")
      expect(ours).to contain_exactly(
        *%i[completed claimed failed].map do |kind|
          have_attributes(database: "timekeeping", queue: "invoice_operations", job_class: "TimekeepingCollectorRowsJob",
                          kind: kind.to_s, job_id: forbidden[kind][:job_id],
                          active_job_id: forbidden[kind][:active_job_id], execution_id: forbidden[kind][:execution_id])
        end
      )
      expect(ours.map(&:queue)).not_to include("timekeeping_relay")
    ensure
      connection.exec_params("DELETE FROM solid_queue_jobs WHERE id = ANY($1::bigint[])", ["{#{job_ids.join(',')}}"])
      connection.exec_params("DELETE FROM solid_queue_processes WHERE id = $1", [process_id]) if process_id
      connection.close
    end
  end
end
