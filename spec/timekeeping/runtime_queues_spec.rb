# frozen_string_literal: true

require "rails_helper"
require "net/http"
require "pg"
require "socket"
require "tempfile"
require "json"

RSpec.describe "Timekeeping demo runtime queues", :two_tenant_seed, committed_data: true do
  dedicated_queues = %w[invoice_operations timekeeping_relay].freeze

  after do
    # A skipped example started nothing, and may run without a Timekeeping database.
    next unless ENV["TIMEKEEPING_LIVE"] == "1"

    queue_tables = ActiveRecord::Base.connection.tables.grep(/\Asolid_queue_/)
    # DatabaseCleaner reads an empty only: list as every table, and skipping
    # the call would leave the Timekeeping queue tables below cleared with no
    # record taken first.
    raise "the monolith test database has no solid_queue_ tables" if queue_tables.empty?

    TestDatabaseCleanup.clean_with!(:truncation, only: queue_tables)
    timekeeping = PG.connect(ENV.fetch("TIMEKEEPING_DATABASE_URL"))
    tables = timekeeping.exec("SELECT tablename FROM pg_tables WHERE tablename LIKE 'solid_queue_%'").column_values(0)
    timekeeping.exec("TRUNCATE #{tables.join(', ')}") if tables.any?
  rescue PG::ConnectionBad
    # The runtime failed before db:prepare created the Timekeeping database,
    # so it holds no queue rows to remove.
    nil
  ensure
    timekeeping&.close
  end

  it "the started runtime finishes dedicated jobs in both databases and never runs a default or billing_sync job" do
    skip "set TIMEKEEPING_LIVE=1 to start the demo runtime" unless ENV["TIMEKEEPING_LIVE"] == "1"

    free_port = lambda do
      server = TCPServer.new("127.0.0.1", 0)
      server.addr[1]
    ensure
      server&.close
    end
    adapter = ActiveJob::QueueAdapters::SolidQueueAdapter.new
    adapter.enqueue(UpdateInvoiceStatusToOverdueJob.new)
    adapter.enqueue(SyncStripeSubscriptionCompanyJob.new(fork_and_leaf.id))
    forbidden_ids = SolidQueue::Job.where.not(queue_name: dedicated_queues).pluck(:id)
    expect(SolidQueue::Job.where(id: forbidden_ids).pluck(:queue_name)).to include("default", "billing_sync")

    started_at = Time.current
    monolith_port = free_port.call
    timekeeping_port = free_port.call
    log = Tempfile.new("timekeeping-demo")
    timekeeping = nil
    pid = Process.spawn(ENV.to_h.merge("RAILS_ENV" => "test", "MONOLITH_PORT" => monolith_port.to_s,
                                       "TIMEKEEPING_PORT" => timekeeping_port.to_s),
                        Rails.root.join("bin/timekeeping-demo").to_s, "up",
                        chdir: Rails.root.to_s, pgroup: true, out: log.path, err: [:child, :out])
    wait_for = lambda do |what, seconds, &check|
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      until check.call
        raise "#{what} not seen within #{seconds}s:\n#{File.read(log.path).lines.last(60).join}" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.5
      end
    end
    finished_here = lambda do |class_name|
      SolidQueue::Job.where(class_name:).where("created_at > ?", started_at).where.not(finished_at: nil).exists?
    end
    # Any HTTP answer shows the server is up. The monolith's /health renders
    # no page, so it answers even when no front-end build is present.
    answers = lambda do |port, path|
      Net::HTTP.start("127.0.0.1", port, open_timeout: 5, read_timeout: 15) do |http|
        http.get(path).code.to_i.positive?
      end
    rescue SystemCallError, IOError, Net::ProtocolError, Timeout::Error
      false
    end

    begin
      # Positive proof first: every dedicated worker ran in this window.
      wait_for.call("a finished monolith relay run", 180) { finished_here.call("Timekeeping::RelayJob") }
      wait_for.call("a finished invoice-operation recovery run", 180) { finished_here.call("RecoverInvoiceOperationIntentsJob") }
      # Connected only now: `up` creates the Timekeeping database with db:prepare
      # before it starts any process, so it may not exist before the runtime starts.
      timekeeping = PG.connect(ENV.fetch("TIMEKEEPING_DATABASE_URL"))
      wait_for.call("a finished Timekeeping relay run", 180) do
        timekeeping.exec_params(<<~SQL, [started_at.utc.iso8601(6)]).getvalue(0, 0) == "t"
          SELECT EXISTS (SELECT 1 FROM solid_queue_jobs WHERE class_name = 'RelayJob'
                         AND created_at > $1::timestamptz AND finished_at IS NOT NULL)
        SQL
      end
      wait_for.call("both web apps answering", 120) { answers.call(monolith_port, "/health") && answers.call(timekeeping_port, "/") }

      # "Add `spec/timekeeping/runtime_queues_spec.rb`, which starts the runtime against a seeded database and fails if a job from `default` or any other non-dedicated queue runs."
      expect(SolidQueue::Job.where(id: forbidden_ids).where.not(finished_at: nil)).to be_empty
      expect(SolidQueue::ClaimedExecution.where(job_id: forbidden_ids)).to be_empty
      expect(SolidQueue::FailedExecution.where(job_id: forbidden_ids)).to be_empty
      expect(SolidQueue::Job.where.not(queue_name: dedicated_queues).where.not(finished_at: nil)).to be_empty
      # A job is claimed while it runs and failed once it raised, so neither may
      # exist for any job outside the dedicated queues, in either database.
      outside_dedicated = SolidQueue::Job.where.not(queue_name: dedicated_queues).select(:id)
      expect(SolidQueue::ClaimedExecution.where(job_id: outside_dedicated)).to be_empty
      expect(SolidQueue::FailedExecution.where(job_id: outside_dedicated)).to be_empty
      ran_outside_relay = timekeeping.exec(<<~SQL).getvalue(0, 0).to_i
        SELECT count(*) FROM solid_queue_jobs
        WHERE queue_name <> 'timekeeping_relay'
          AND (finished_at IS NOT NULL
               OR EXISTS (SELECT 1 FROM solid_queue_claimed_executions claimed WHERE claimed.job_id = solid_queue_jobs.id)
               OR EXISTS (SELECT 1 FROM solid_queue_failed_executions failed WHERE failed.job_id = solid_queue_jobs.id))
      SQL
      expect(ran_outside_relay).to eq(0)

      worker_queues = SolidQueue::Process.where(kind: "Worker").map do |process|
        metadata = process.metadata.is_a?(String) ? JSON.parse(process.metadata) : process.metadata
        Array(metadata["queues"]).flat_map { |queues| queues.to_s.split(",") }.map(&:strip)
      end
      expect(worker_queues.flatten.uniq).to match_array(dedicated_queues)

      # Timekeeping runs only its relay worker, so no other queue (and no "*") has a worker there.
      timekeeping_worker_queues = timekeeping.exec("SELECT metadata FROM solid_queue_processes WHERE kind = 'Worker'")
        .column_values(0).flat_map do |metadata|
          Array(JSON.parse(metadata || "{}")["queues"]).flat_map { |queues| queues.to_s.split(",") }.map(&:strip)
        end
      expect(timekeeping_worker_queues.uniq).to eq(["timekeeping_relay"])

      versions = JSON.parse(Rails.root.join("tmp/timekeeping-demo/versions.json").read)
      expect(versions.keys).to include("monolith", "timekeeping")
    ensure
      begin
        Process.kill("TERM", -pid)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
        sleep 0.2 while Process.waitpid(pid, Process::WNOHANG).nil? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        Process.kill("KILL", -pid)
        Process.waitpid(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      timekeeping&.close
      log.close!
    end

    expect { Process.kill(0, -pid) }.to raise_error(Errno::ESRCH)
  end
end
