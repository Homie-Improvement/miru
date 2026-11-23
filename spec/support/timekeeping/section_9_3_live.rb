# frozen_string_literal: true

require "delegate"
require "fileutils"
require "json"
require "net/http"
require "pathname"
require "pg"
require "tmpdir"

# Helpers for the live section 9.3 examples in
# spec/integration/timekeeping/section_9_3_spec.rb. They run inside an
# :integrated_runtime example, after IntegratedRuntime.start has booted both
# apps and activated the queue ledger.
#
# Errors raised here never carry an environment value, a database URL or a
# child's output: the environment holds the runtime's private key, a URL can
# hold a password, and these errors end up in CI logs.
module TimekeepingSection93Live
  class CutoverAborted < StandardError; end
  class TimekeepingReadError < StandardError; end
  class PollTimeout < StandardError; end
  class PrepareSendError < StandardError; end

  HANDOFF_INITIALIZER = "config/initializers/timekeeping_handoff.rb"
  DEFAULT_POLL_SECONDS = 30
  POLL_INTERVAL_SECONDS = 0.1
  # How long a lock check waits for the server to report a wait, as
  # CommittedDataMode::Helpers#blocked_by? does by default.
  LOCK_WAIT_SECONDS = 3
  # Every hold and every parked save gives up after this long, so a release
  # an example never sends cannot keep a lock into the next example.
  HOLD_LIMIT_SECONDS = DEFAULT_POLL_SECONDS
  # A prepare held on an entry row must outlast the hold, which the 5 s
  # timeout of Timekeeping::ReservationHttp does not.
  PREPARE_READ_TIMEOUT_SECONDS = HOLD_LIMIT_SECONDS * 2
  PREPARED_STATE = "prepared"
  SAVE_CHECKPOINT_KEY = :section_9_3_save_checkpoint

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

  # The row lock Timekeeping::ReservationOperations#lock_entries takes.
  ENTRY_HOLD_SQL = "SELECT id FROM entries WHERE company_id = $1 AND id = $2 FOR UPDATE"

  # Every session on the named database that waits on the holder, directly or
  # behind another waiter. PostgreSQL can queue a second FOR UPDATE on the
  # tuple lock of the first waiter, so its direct blocker is that waiter.
  TIMEKEEPING_WAITERS_SQL = <<~SQL.squish
    WITH RECURSIVE waiting(pid) AS (
      SELECT pid FROM pg_stat_activity
      WHERE datname = %<database>s AND %<holder>d = ANY(pg_blocking_pids(pid))
      UNION
      SELECT activity.pid FROM pg_stat_activity activity
      JOIN waiting ON waiting.pid = ANY(pg_blocking_pids(activity.pid))
      WHERE activity.datname = %<database>s
    )
    SELECT pid FROM waiting ORDER BY pid
  SQL

  TIMEKEEPING_BLOCKED_BY_SQL = <<~SQL.squish
    SELECT EXISTS (
      SELECT 1 FROM pg_stat_activity
      WHERE pid = %<waiting>d AND datname = %<database>s AND %<holder>d = ANY(pg_blocking_pids(pid))
    )
  SQL

  ADVISORY_WAIT_SQL = <<~SQL.squish
    SELECT EXISTS (SELECT 1 FROM pg_locks WHERE pid = %<waiting>d AND locktype = 'advisory' AND NOT granted)
  SQL

  # A Timekeeping entry row held FOR UPDATE by a thread of its own, on the
  # backend pid. The thread commits once released, or once the hold limit
  # passes.
  TimekeepingEntryHold = Data.define(:thread, :pid, :release) do
    def release!
      release << true
    end
  end

  # What one raw prepare answered: the HTTP status and the parsed JSON body,
  # nil when the body is empty or not JSON.
  PrepareAnswer = Data.define(:status, :body)

  # The request ReservationClient would send, kept instead of sent, so a raw
  # prepare carries exactly the client's route, token and body.
  class CapturedReservationRequest
    attr_reader :http_method, :path, :headers, :body

    def call(http_method, path, headers:, body:)
      @http_method = http_method
      @path = path
      @headers = headers
      @body = body
      nil
    end
  end

  # Where a save parks in a thread of this process: reached reports the
  # save's backend pid and waits for release!, bounded by the hold limit.
  ThreadSaveCheckpoint = Data.define(:reported, :release) do
    def self.open
      new(reported: Queue.new, release: Queue.new)
    end

    def reached(backend_pid)
      reported << backend_pid
      release.pop(timeout: HOLD_LIMIT_SECONDS)
    end

    def release!
      release << true
    end

    # The parked save's backend pid; raises PollTimeout when the save does
    # not reach the checkpoint in time.
    def await_backend_pid(description, within: DEFAULT_POLL_SECONDS)
      reported.pop(timeout: within) ||
        raise(PollTimeout, "#{description} did not reach its checkpoint within #{within} s")
    end
  end

  # Where a save parks in a forked child: reached writes the save's backend
  # pid to the parent and stops the child with SIGSTOP, so no Ruby code (no
  # ensure block, no after_rollback callback) runs before the parent's
  # SIGKILL. That is what makes it a crash rather than a failure.
  ForkSaveCheckpoint = Data.define(:writer) do
    def reached(backend_pid)
      writer.puts(Integer(backend_pid))
      writer.flush
      Process.kill(:STOP, Process.pid)
    end
  end

  # A forked child parked at its checkpoint: its process id, and the backend
  # pid of the database session its save holds.
  ParkedChild = Data.define(:pid, :backend_pid)

  # Wraps a reservation adapter so the save running on a thread that carries
  # a checkpoint parks there once the adapter answers `prepared`. That is
  # before Invoices::OperationCoordinator#call runs settle, so the save holds
  # the invoice's advisory lock but no lock on its intent row. Each checkpoint
  # is used once.
  class CheckpointedReservations < SimpleDelegator
    def prepare(request)
      outcome = __getobj__.prepare(request)
      checkpoint = Thread.current.thread_variable_get(SAVE_CHECKPOINT_KEY)
      if checkpoint && outcome.state == PREPARED_STATE
        Thread.current.thread_variable_set(SAVE_CHECKPOINT_KEY, nil)
        checkpoint.reached(ApplicationRecord.connection.select_value("SELECT pg_backend_pid()"))
      end
      outcome
    end
  end

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

  # Holds the entry's Timekeeping row FOR UPDATE, the mode lock_entries takes,
  # on a connection of its own to the Timekeeping database. Answers once the
  # row is held; raises PollTimeout when the hold does not report in time.
  # Stop the hold's thread with stop_committed_data_threads in ensure.
  def section_9_3_hold_timekeeping_entry(company_id:, entry_id:, within: DEFAULT_POLL_SECONDS)
    reported = Queue.new
    release = Queue.new
    params = [Integer(company_id), Integer(entry_id)]
    thread = Thread.new do
      section_9_3_with_timekeeping_connection("a hold on entry #{params.last}") do |connection|
        connection.transaction do
          if connection.exec_params(ENTRY_HOLD_SQL, params).ntuples.zero?
            raise TimekeepingReadError, "entry #{params.last} of company #{params.first} is not in Timekeeping"
          end

          reported << connection.backend_pid
          release.pop(timeout: HOLD_LIMIT_SECONDS)
        end
      end
    ensure
      reported.close
    end
    pid = reported.pop(timeout: within)
    raise PollTimeout, "the hold on entry #{entry_id} did not report its backend within #{within} s" unless pid

    TimekeepingEntryHold.new(thread:, pid:, release:)
  end

  # The backend pids of Timekeeping sessions that wait on holding_pid's
  # locks, directly or behind another waiter, once at least count of them
  # wait; what was seen when the wait runs out otherwise. Prove each direct
  # wait with section_9_3_timekeeping_blocked_by?.
  def section_9_3_timekeeping_waiters(holding_pid, count:, within: LOCK_WAIT_SECONDS)
    database = section_9_3_timekeeping_database_name
    section_9_3_observe_locks(within, satisfied: ->(pids) { pids.size >= count }) do |observer|
      query = format(TIMEKEEPING_WAITERS_SQL, database: observer.quote(database), holder: Integer(holding_pid))
      observer.select_values(query).map { |pid| Integer(pid) }
    end
  end

  # blocked_by? for Timekeeping's sessions: true once the server reports the
  # Timekeeping session waiting_pid blocked by holding_pid's locks; false when
  # that has not happened within the given seconds. Both test databases share
  # one PostgreSQL server, so a monolith connection can read the wait.
  def section_9_3_timekeeping_blocked_by?(waiting_pid, holding_pid, within: LOCK_WAIT_SECONDS)
    database = section_9_3_timekeeping_database_name
    section_9_3_observe_locks(within, satisfied: :itself.to_proc) do |observer|
      query = format(TIMEKEEPING_BLOCKED_BY_SQL,
                     waiting: Integer(waiting_pid), database: observer.quote(database), holder: Integer(holding_pid))
      observer.select_value(query)
    end
  end

  # True once the session waiting_pid waits for an advisory lock, such as the
  # invoice-identity lock Invoices::OperationLock takes; false when that has
  # not happened within the given seconds. blocked_by? alone cannot tell this
  # wait from a wait on the invoices row.
  def section_9_3_advisory_wait?(waiting_pid, within: LOCK_WAIT_SECONDS)
    section_9_3_observe_locks(within, satisfied: :itself.to_proc) do |observer|
      observer.select_value(format(ADVISORY_WAIT_SQL, waiting: Integer(waiting_pid)))
    end
  end

  # Sends a prepare for the request straight to Timekeeping from a plain
  # thread, with a read timeout that outlasts an entry hold. The thread's
  # value is a PrepareAnswer with the real status and body, which
  # ReservationClient would map to an outcome. A transport error raises
  # PrepareSendError when the thread is joined, so it is never read as an
  # answer.
  def section_9_3_raw_prepare_thread(request)
    captured = CapturedReservationRequest.new
    Timekeeping::ReservationClient.new(http: captured).prepare(request)
    raise PrepareSendError, "ReservationClient sent no prepare to capture" unless captured.path

    uri = URI.join(@integrated_runtime.timekeeping_url, captured.path)
    http_request = Net::HTTPGenericRequest.new(captured.http_method.to_s.upcase, true, true, uri)
    captured.headers.each { |name, value| http_request[name] = value }
    http_request["Content-Type"] = "application/json"
    http_request.body = JSON.generate(captured.body)
    Thread.new { section_9_3_send_prepare(uri, http_request) }
  end

  # Makes every invoice save that runs on a thread carrying a checkpoint park
  # there once Timekeeping answers its prepare `prepared`. Call once per
  # example, before the saves start; saves on other threads are untouched.
  def section_9_3_park_saves_after_prepare!
    allow(Invoices::ReservationAdapters).to receive(:for).and_wrap_original do |original, *args, **kwargs|
      CheckpointedReservations.new(original.call(*args, **kwargs))
    end
  end

  # Runs the block with the checkpoint on the current thread, so the first
  # save in it that prepares parks there.
  def section_9_3_with_save_checkpoint(checkpoint)
    Thread.current.thread_variable_set(SAVE_CHECKPOINT_KEY, checkpoint)
    yield
  ensure
    Thread.current.thread_variable_set(SAVE_CHECKPOINT_KEY, nil)
  end

  # Forks a child that runs the block with a ForkSaveCheckpoint, and answers
  # once the child reports its save's backend pid from that checkpoint. The
  # child opens its own database connections: Rails discards the inherited
  # pools after a fork. It leaves only through SIGKILL or exit!, so it never
  # runs at_exit or RSpec hooks. Kill it with section_9_3_kill! in ensure.
  # A child that does not report in time is killed here and PollTimeout is
  # raised.
  def section_9_3_fork_parked(description, within: DEFAULT_POLL_SECONDS, &child_body)
    reader, writer = IO.pipe
    pid = Process.fork do
      reader.close
      begin
        child_body.call(ForkSaveCheckpoint.new(writer:))
      ensure
        # Reached only when the child never parked: nothing the parent waits
        # for will come, so end at once and let the parent report it.
        Kernel.exit!(false)
      end
    end
    writer.close
    backend_pid = section_9_3_read_backend_pid(reader, within)
    unless backend_pid
      section_9_3_kill!(ParkedChild.new(pid:, backend_pid: nil))
      raise PollTimeout, "#{description} did not reach its checkpoint within #{within} s"
    end

    ParkedChild.new(pid:, backend_pid:)
  ensure
    [reader, writer].compact.reject(&:closed?).each(&:close)
  end

  # Sends SIGKILL to the child and reaps it. Safe on a child already gone.
  def section_9_3_kill!(child)
    return unless child

    begin
      Process.kill(:KILL, child.pid)
    rescue Errno::ESRCH
      nil
    end
    begin
      Process.wait(child.pid)
    rescue Errno::ECHILD
      nil
    end
  end

  # Pauses the invoice_operations queue while the block runs, so the
  # runtime's recurring RecoverInvoiceOperationIntentsJob sweep cannot
  # resolve an intent before the example's own in-process recovery does.
  def section_9_3_with_recovery_queue_paused
    queue = SolidQueue::Queue.new(RecoverInvoiceOperationIntentsJob.queue_name)
    queue.pause
    yield
  ensure
    queue&.resume
  end

  private

    # Reruns only the handoff initializer's own to_prepare block. Rerunning
    # every to_prepare hook reloads FactoryBot, which fails on the seed's
    # top-level helper methods.
    def section_9_3_rebuild_handoff_integrations
      allow(Rails.application.config).to receive(:to_prepare).and_yield
      load Rails.root.join(HANDOFF_INITIALIZER).to_s
    end

    # Opens a short-lived connection for one read-only query and answers its
    # rows with symbol keys and decoded column types.
    def section_9_3_timekeeping_rows(purpose, sql, params)
      section_9_3_with_timekeeping_connection(purpose) do |connection|
        connection.type_map_for_results = PG::BasicTypeMapForResults.new(connection)
        connection.exec_params(sql, params).map { |row| row.transform_keys(&:to_sym) }
      end
    end

    # Yields a new connection to the Timekeeping test database and closes it
    # after. A connection or query error is replaced by one that names only
    # the purpose, because the original can carry the URL's host or password.
    def section_9_3_with_timekeeping_connection(purpose)
      url = ENV.fetch(TimekeepingDatabaseReset::DATABASE_URL_KEY) do
        raise TimekeepingReadError, "#{TimekeepingDatabaseReset::DATABASE_URL_KEY} is not set; cannot read #{purpose}"
      end
      TestDatabaseGuard.require_test_database_url!(url)
      begin
        connection = PG.connect(url)
        yield connection
      rescue PG::Error
        raise TimekeepingReadError, "could not read #{purpose} from the Timekeeping database", cause: nil
      ensure
        connection&.close
      end
    end

    # Read from the server rather than parsed from the URL, so no URL text
    # can reach an error.
    def section_9_3_timekeeping_database_name
      section_9_3_timekeeping_rows("the database name", "SELECT current_database() AS name", []).first.fetch(:name)
    end

    # Runs the lock query on a connection opened outside the pool, as
    # blocked_by? does, until satisfied answers true for its value or the
    # wait runs out, and answers the last value.
    def section_9_3_observe_locks(within, satisfied:)
      observer = ActiveRecord::Base.connection_pool.db_config.new_connection
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
      loop do
        observed = yield observer
        return observed if satisfied.call(observed) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep CommittedDataMode::Helpers::BLOCKER_POLL_INTERVAL
      end
    ensure
      observer&.disconnect!
    end

    def section_9_3_send_prepare(uri, http_request)
      response = Net::HTTP.start(uri.host, uri.port, open_timeout: LOCK_WAIT_SECONDS,
                                                     read_timeout: PREPARE_READ_TIMEOUT_SECONDS) do |http|
        http.request(http_request)
      end
      PrepareAnswer.new(status: response.code.to_i, body: section_9_3_parse_json(response.body))
    rescue *Timekeeping::ReservationHttp::TRANSPORT_ERRORS => error
      raise PrepareSendError, "raw prepare to Timekeeping failed: #{error.class}", cause: nil
    end

    def section_9_3_parse_json(raw)
      raw.to_s.empty? ? nil : JSON.parse(raw)
    rescue JSON::ParserError
      nil
    end

    # The first line the child writes, as an Integer, or nil when the child
    # closes the pipe or the wait runs out first.
    def section_9_3_read_backend_pid(reader, within)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
      buffer = +""
      until buffer.include?("\n")
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return nil if remaining <= 0 || IO.select([reader], nil, nil, remaining).nil?

        chunk = reader.read_nonblock(64, exception: false)
        return nil if chunk.nil?

        buffer << chunk unless chunk == :wait_readable
      end
      Integer(buffer.lines.first.strip)
    end
end

RSpec.configure do |config|
  config.include TimekeepingSection93Live, integrated_runtime: true
end
