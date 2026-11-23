# frozen_string_literal: true

require "fileutils"
require "io/wait"
require "json"
require "pathname"
require "pg"
require "tmpdir"

# Helpers for the live section 9.3 examples in
# spec/integration/timekeeping/section_9_3_spec.rb. They run inside an
# :integrated_runtime example, after IntegratedRuntime.start has booted both
# apps and activated the queue ledger.
#
# Errors raised here never carry an environment value, a database URL or a
# child's output (of a crash child, only its error's class name): the environment holds the runtime's private key, a URL can
# hold a password, and these errors end up in CI logs.
module TimekeepingSection93Live
  class CutoverAborted < StandardError; end
  class TimekeepingReadError < StandardError; end
  class PollTimeout < StandardError; end
  class CrashChildFailed < StandardError; end

  HANDOFF_INITIALIZER = "config/initializers/timekeeping_handoff.rb"
  DEFAULT_POLL_SECONDS = 30
  POLL_INTERVAL_SECONDS = 0.1
  # The same default wait as blocked_by? in spec/support/committed_data.rb.
  # It stays under the 5 s HTTP timeout of Timekeeping::EntryApiClient and
  # under RecoverInvoiceOperationIntentsJob::LOCK_WAIT_TIMEOUT, so a wait is
  # seen while the waiter is still waiting.
  LOCK_OBSERVE_SECONDS = 3
  CRASH_CHECKPOINT_SECONDS = 30

  ENTRY_HOLD_SQL = "SELECT id FROM entries WHERE company_id = $1 AND id = $2 FOR UPDATE"

  # True when the session is waiting on the given Timekeeping backend's locks
  # and is itself connected to the Timekeeping database.
  TIMEKEEPING_BLOCKED_BY_SQL = <<~SQL.squish
    SELECT EXISTS (
      SELECT 1 FROM pg_stat_activity
      WHERE pid = $1 AND datname = $2 AND $3 = ANY(pg_blocking_pids(pid))
    )
  SQL

  # Sessions on the Timekeeping database waiting on the holder, directly or
  # behind another waiter. Two sessions that wait for one locked row queue:
  # the second waits on the first waiter, not on the holder.
  TIMEKEEPING_WAITERS_SQL = <<~SQL.squish
    WITH RECURSIVE waiting(pid) AS (
      SELECT pid FROM pg_stat_activity
      WHERE datname = $1 AND $2 = ANY(pg_blocking_pids(pid))
      UNION
      SELECT activity.pid FROM pg_stat_activity activity
      JOIN waiting ON waiting.pid = ANY(pg_blocking_pids(activity.pid))
      WHERE activity.datname = $1
    )
    SELECT pid FROM waiting ORDER BY pid
  SQL

  # A bigint advisory lock is listed in pg_locks with its high 32 bits in
  # classid, its low 32 bits in objid and objsubid 1. The key is built the
  # way Invoices::OperationLock.acquire! builds it.
  OPERATION_LOCK_SQL = <<~SQL.squish
    SELECT EXISTS (
      SELECT 1 FROM pg_locks
      WHERE pid = $1 AND locktype = 'advisory' AND objsubid = 1 AND granted = $2
        AND ((classid::bigint << 32) | objid::bigint) = hashtextextended($3, 0)
    )
  SQL

  BACKEND_PRESENT_SQL = "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid = $1)"

  RESERVATIONS_SQL = <<~SQL.squish
    SELECT company_id, entry_id, invoice_id, state, disposition, operation_id::text AS operation_id
    FROM reservations
    WHERE company_id = $1 AND entry_id = ANY($2::bigint[])
    ORDER BY entry_id, state, invoice_id
  SQL

  OPERATIONS_SQL = <<~SQL.squish
    SELECT company_id, invoice_id, operation_id::text AS operation_id, state, disposition, desired_entry_ids, generation
    FROM invoice_operations
    WHERE company_id = $1 AND invoice_id = $2
    ORDER BY id
  SQL

  # Runs the block with the runtime's credentials and Timekeeping URL in ENV,
  # because in-process saves mint service tokens from
  # TIMEKEEPING_TOKEN_PRIVATE_KEY and ReservationHttp reads the base URL there;
  # IntegratedRuntime.start passes them only to its child processes. The
  # handoff initializer is rerun inside, so the integrations it builds read the
  # live values, and rerun again once ENV is restored.
  def section_9_3_live_context(&block)
    runtime = @integrated_runtime
    raise ArgumentError, "section_9_3_live_context needs a started :integrated_runtime example" unless runtime

    live_env = runtime.credentials.to_env.merge(Timekeeping::EntryApiClient::BASE_URL_ENV => runtime.timekeeping_url)
    with_timekeeping_env(live_env) do
      section_9_3_rebuild_handoff_integrations
      block.call
    end
  ensure
    section_9_3_rebuild_handoff_integrations if runtime
  end

  # Runs a real cutover with the configured owners and answers the new
  # ownership generation. Raises before any row assertion runs when the run's
  # reconciliation report is missing or says the cutover aborted.
  def section_9_3_cutover!
    report_root = Pathname(Dir.mktmpdir("timekeeping-section-9-3"))
    Timekeeping::Handoff::Runner.run(
      direction: :cutover, owners: Timekeeping::Handoff::Runner.configured_owners, report_root:
    )
    generation = TimekeepingOwnership.uncached do
      TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID).pick(:generation)
    end
    report_file = Timekeeping::Handoff::ReportDirectory::RECONCILIATION_FILE
    report_path = Timekeeping::Handoff::ReportDirectory.new(root: report_root, generation:).path.join(report_file)
    raise CutoverAborted, "cutover wrote no #{report_file} for generation #{generation}" unless report_path.file?
    raise CutoverAborted, "cutover reconciliation reports abort: true" if JSON.parse(report_path.read).fetch("abort")

    generation
  ensure
    FileUtils.rm_rf(report_root) if report_root
  end

  # Every reservation Timekeeping holds on the given entries of one company,
  # read from its own database, because the stored entries.locked column is
  # not kept current.
  def section_9_3_timekeeping_reservations(company_id:, entry_ids:)
    ids = PG::TextEncoder::Array.new.encode(entry_ids.map { |id| Integer(id) })
    section_9_3_timekeeping_rows("reservations", RESERVATIONS_SQL, [Integer(company_id), ids])
  end

  # Every invoice operation Timekeeping stores for one invoice of one company.
  def section_9_3_timekeeping_operations(company_id:, invoice_id:)
    section_9_3_timekeeping_rows("invoice operations", OPERATIONS_SQL, [Integer(company_id), Integer(invoice_id)])
  end

  # Reads observe until satisfied answers true for what it returned, and
  # answers that value. A fixed deadline on the monotonic clock bounds the
  # wait; on timeout the error names what was awaited and the last value seen,
  # which the caller keeps to ids and states.
  def section_9_3_poll_until(description, within: DEFAULT_POLL_SECONDS, satisfied: :itself.to_proc, &observe)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
    loop do
      observed = observe.call
      return observed if satisfied.call(observed)

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        raise PollTimeout, "#{description} not reached within #{within} s; last observed: #{observed.inspect}"
      end

      sleep POLL_INTERVAL_SECONDS
    end
  end

  # Holds one entry row on the Timekeeping database in the mode Timekeeping's
  # own prepare locks it (Timekeeping::ReservationOperations#lock_entries takes
  # FOR UPDATE), pushes the holding session's backend pid to holder_pids, and
  # keeps the lock until something is pushed to release. Meant to run as the
  # body of a committed_data_thread; the connection closes when it returns.
  def section_9_3_hold_timekeeping_entry(company_id:, entry_id:, holder_pids:, release:)
    section_9_3_with_timekeeping_connection("hold an entry row") do |connection|
      connection.transaction do
        held = connection.exec_params(ENTRY_HOLD_SQL, [Integer(company_id), Integer(entry_id)])
        raise TimekeepingReadError, "Timekeeping has no entry #{entry_id} for company #{company_id}" if held.ntuples.zero?

        holder_pids << Integer(connection.exec("SELECT pg_backend_pid()").getvalue(0, 0))
        release.pop
      end
    end
  end

  # The Timekeeping-side twin of blocked_by?: true once the Timekeeping
  # database session waiting_pid is blocked by holding_pid's locks; false when
  # that has not happened within the given seconds.
  def section_9_3_timekeeping_blocked_by?(waiting_pid, holding_pid, within: LOCK_OBSERVE_SECONDS)
    params = [Integer(waiting_pid), section_9_3_timekeeping_database_name, Integer(holding_pid)]
    section_9_3_observe_server(within) do |observer|
      observer.exec_params(TIMEKEEPING_BLOCKED_BY_SQL, params).getvalue(0, 0) == true
    end
  end

  # The backend pids of Timekeeping server sessions waiting on holding_pid's
  # locks, directly or queued behind another such session, in pid order, once
  # at least count of them wait; whatever was last
  # seen, possibly fewer, when the given seconds pass first. The test cannot
  # learn these pids any other way: the Timekeeping server opens them.
  def section_9_3_timekeeping_waiters(holding_pid, count:, within: LOCK_OBSERVE_SECONDS)
    params = [section_9_3_timekeeping_database_name, Integer(holding_pid)]
    waiters = []
    section_9_3_observe_server(within) do |observer|
      waiters = observer.exec_params(TIMEKEEPING_WAITERS_SQL, params).column_values(0).map { |pid| Integer(pid) }
      waiters.size >= count
    end
    waiters
  end

  # True once the monolith session backend_pid holds (granted: true) or waits
  # for (granted: false) the invoice-identity advisory lock of one invoice;
  # false when that has not happened within the given seconds. blocked_by?
  # alone cannot tell this wait from a wait on a row lock.
  def section_9_3_operation_lock?(backend_pid, company_id:, invoice_id:, granted:, within: LOCK_OBSERVE_SECONDS)
    params = [Integer(backend_pid), granted, Invoices::OperationLock.key(company_id:, invoice_id:)]
    section_9_3_observe_server(within) do |observer|
      observer.exec_params(OPERATION_LOCK_SQL, params).getvalue(0, 0) == true
    end
  end

  # Simulates a crash of an invoice save. The block runs in a forked child and
  # receives a checkpoint: a callable the save calls where the crash belongs.
  # At the checkpoint the child reports its database backend pid through a
  # pipe and parks. The parent checks that backend holds the invoice's
  # operation lock, sends the child SIGKILL, reaps it, and waits until the
  # server has ended the backend, which rolls back its open transaction and
  # frees its locks. Answers the killed backend's pid.
  #
  # A killed Ruby thread is no crash: Ruby would run its ensure blocks and the
  # transaction's after_rollback callback, which record the failure. SIGKILL
  # runs nothing in the child.
  def section_9_3_crash_at_checkpoint(company_id:, invoice_id:, within: CRASH_CHECKPOINT_SECONDS, &save)
    reader, writer = IO.pipe
    child = Process.fork { section_9_3_run_crash_child(reader, writer, &save) }
    writer.close
    backend_pid = section_9_3_read_checkpoint(reader, within)
    unless section_9_3_operation_lock?(backend_pid, company_id:, invoice_id:, granted: true, within: 0)
      raise CrashChildFailed, "the crash child's backend does not hold invoice #{invoice_id}'s operation lock at its checkpoint"
    end

    Process.kill(:KILL, child)
    Process.wait(child)
    child = nil
    ended = section_9_3_observe_server(DEFAULT_POLL_SECONDS) do |observer|
      observer.exec_params(BACKEND_PRESENT_SQL, [backend_pid]).getvalue(0, 0) == false
    end
    raise PollTimeout, "killed backend #{backend_pid} still connected after #{DEFAULT_POLL_SECONDS} s" unless ended

    backend_pid
  ensure
    section_9_3_reap_crash_child(child) if child
    reader&.close
    writer&.close
  end

  # Pauses the queue the invoice operation worker sweeps, so its recurring
  # recovery cannot race a recovery the example runs in-process, and resumes
  # it when the block ends, failed assertion or not.
  def section_9_3_with_paused_invoice_operations
    queue = SolidQueue::Queue.find_by_name(RecoverInvoiceOperationIntentsJob.queue_name)
    queue.pause
    yield
  ensure
    queue&.resume
  end

  private

    # Child side of section_9_3_crash_at_checkpoint. Every way out ends in
    # exit!, so the child never runs RSpec's at_exit hooks or the parent's
    # ensure blocks. Rails gives a forked child fresh connection pools, so
    # the save never uses a connection the parent holds.
    def section_9_3_run_crash_child(reader, writer)
      reader.close
      checkpoint = lambda do
        writer.puts(ApplicationRecord.with_connection { |connection| connection.select_value("SELECT pg_backend_pid()") })
        writer.flush
        # Parks the save with its transaction open until the parent's SIGKILL.
        sleep
      end
      yield checkpoint
      writer.puts("finished")
    rescue Exception => error # rubocop:disable Lint/RescueException -- the child reports any error, then exits
      writer.puts("raised #{error.class.name}")
    ensure
      Process.exit!(false)
    end

    # The backend pid the crash child reports at its checkpoint. Only the
    # class of a child's error crosses the pipe, never its message.
    def section_9_3_read_checkpoint(reader, within)
      raise PollTimeout, "crash child did not reach its checkpoint within #{within} s" unless reader.wait_readable(within)

      report = reader.gets&.chomp
      return Integer(report) if report&.match?(/\A\d+\z/)

      raise CrashChildFailed, "crash child #{report || 'exited'} before its checkpoint"
    end

    def section_9_3_reap_crash_child(child)
      Process.kill(:KILL, child)
    rescue Errno::ESRCH
      # Already gone; it still has to be reaped.
    ensure
      begin
        Process.wait(child)
      rescue Errno::ECHILD
        # Already reaped.
      end
    end

    # Yields a raw connection to the monolith's database server, opened
    # outside the pool, whose results Rails decodes to Ruby values (booleans,
    # integers), until the block answers truthy or the given seconds
    # pass, and answers the block's last value. Both test databases share one
    # server, so this connection sees Timekeeping's sessions and lock waits
    # too. It is outside the pool because the threads under test can lease
    # every pooled connection.
    def section_9_3_observe_server(within)
      observer = ActiveRecord::Base.connection_pool.db_config.new_connection
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
      loop do
        observed = yield observer.raw_connection
        return observed if observed || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep CommittedDataMode::Helpers::BLOCKER_POLL_INTERVAL
      end
    ensure
      observer&.disconnect!
    end

    def section_9_3_timekeeping_database_name
      PG::Connection.conninfo_parse(section_9_3_timekeeping_database_url).find { |option| option[:keyword] == "dbname" }
                    .fetch(:val)
    rescue PG::Error
      raise TimekeepingReadError, "#{TimekeepingDatabaseReset::DATABASE_URL_KEY} does not parse", cause: nil
    end

    def section_9_3_timekeeping_database_url
      url = ENV.fetch(TimekeepingDatabaseReset::DATABASE_URL_KEY) do
        raise TimekeepingReadError, "#{TimekeepingDatabaseReset::DATABASE_URL_KEY} is not set"
      end
      TestDatabaseGuard.require_test_database_url!(url)
      url
    end

    # Opens a connection to the Timekeeping database for the block and closes
    # it after. A connection or query error is replaced by one that names only
    # what was being done, because the original can carry the URL's host or
    # password.
    def section_9_3_with_timekeeping_connection(purpose)
      url = section_9_3_timekeeping_database_url
      begin
        connection = PG.connect(url)
        yield connection
      rescue PG::Error
        raise TimekeepingReadError, "could not #{purpose} on the Timekeeping database", cause: nil
      ensure
        connection&.close
      end
    end

    # Reruns only the handoff initializer's own to_prepare block. Rerunning
    # every to_prepare hook reloads FactoryBot, which fails on the seed's
    # top-level helper methods.
    def section_9_3_rebuild_handoff_integrations
      allow(Rails.application.config).to receive(:to_prepare).and_yield
      load Rails.root.join(HANDOFF_INITIALIZER).to_s
    end

    # Runs one read-only query on a short-lived connection and answers its
    # rows with symbol keys and decoded column types.
    def section_9_3_timekeeping_rows(purpose, sql, params)
      section_9_3_with_timekeeping_connection("read #{purpose}") do |connection|
        connection.type_map_for_results = PG::BasicTypeMapForResults.new(connection)
        connection.exec_params(sql, params).map { |row| row.transform_keys(&:to_sym) }
      end
    end
end

RSpec.configure do |config|
  config.include TimekeepingSection93Live, integrated_runtime: true
end
