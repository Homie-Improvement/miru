# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

# The queue ledger proves that no job from a non-dedicated queue executed
# during a live Timekeeping proof run. The Solid Queue tables are emptied on
# every database reset, so what the ledger finds is kept in a JSON file
# outside the cleaned tables, and the run is judged from that file.
#
# This part is the pure core: the dedicated queues, the record shapes, the
# verdict and the file format.
module TimekeepingQueueLedger
  # Queues the demo runtime's workers are allowed to run, per database, as
  # spec/timekeeping/runtime_queues_spec.rb has them. The monolith runs the
  # invoice operation worker and its relay; Timekeeping runs only its relay.
  DEDICATED_QUEUES = {
    "monolith" => %w[invoice_operations timekeeping_relay].freeze,
    "timekeeping" => %w[timekeeping_relay].freeze
  }.freeze

  # Only identifiers and timestamps are kept. Job arguments and a failed
  # execution's error text can hold customer data or connection strings, so
  # they never reach the file.
  Record = Data.define(:database, :queue, :job_class, :kind, :job_id, :active_job_id, :execution_id,
                       :created_at, :finished_at)

  # status is "unrun", "ran" or "missing" once checked, and nil before. A
  # control is found by its active_job_id: a reset that restarts the id
  # sequence can give its integer job_id to a different job.
  Control = Data.define(:queue, :job_class, :job_id, :active_job_id, :status)

  Verdict = Data.define(:failures) do
    def passed?
      failures.empty?
    end
  end

  class UnreadableLedger < StandardError; end

  UNRUN = "unrun"

  module_function

  def verdict(records:, controls:, dedicated_queues:)
    control_ids = controls.to_set(&:active_job_id)
    ran_ids = records.filter_map { |record| record.active_job_id if control_ids.include?(record.active_job_id) }.to_set
    control_failures = controls.filter_map { |control| control_failure(control, ran_ids) }
    execution_failures = records.filter_map do |record|
      next if control_ids.include?(record.active_job_id)

      execution_failure(record, dedicated_queues)
    end
    Verdict.new(failures: (control_failures + execution_failures).uniq.freeze)
  end

  def parse(text)
    document = JSON.parse(text)
    raise UnreadableLedger, "the queue ledger is not an object with records and controls" unless ledger_shape?(document)

    {
      records: document.fetch("records").map { |fields| Record.new(**fields.transform_keys(&:to_sym)) }.freeze,
      controls: document.fetch("controls").map { |fields| Control.new(**fields.transform_keys(&:to_sym)) }.freeze
    }.freeze
  rescue JSON::ParserError, ArgumentError, TypeError
    raise UnreadableLedger, "the queue ledger file cannot be parsed", cause: nil
  end

  def serialize(records:, controls:)
    JSON.generate(
      "records" => records.map { |record| json_fields(record) },
      "controls" => controls.map { |control| json_fields(control) }
    )
  end

  # Adds to what the file already holds. The new content goes to a temp file
  # in the same directory, then a rename replaces the ledger in one step, so a
  # crash mid-write never leaves a half-written ledger behind.
  def write(path, records:, controls:)
    stored = File.exist?(path) ? parse(File.read(path)) : { records: [], controls: [] }
    merged_records = (stored[:records] + records).uniq { |record| record_key(record) }
    FileUtils.mkdir_p(File.dirname(path))
    temp_path = "#{path}.#{Process.pid}.tmp"
    File.write(temp_path, serialize(records: merged_records, controls: merge_controls(stored[:controls], controls)))
    File.rename(temp_path, path)
    nil
  ensure
    FileUtils.rm_f(temp_path) if temp_path
  end

  # The queues among those given that the database's workers may not run, in
  # the order given. Raises KeyError for a database the ledger does not know.
  def non_dedicated_queues(queues, database:)
    dedicated = DEDICATED_QUEUES.fetch(database)
    queues.reject { |queue| dedicated.include?(queue) }
  end

  # The queue of every job performed in this process while the block runs,
  # in the order they started. A job run with perform_now writes no Solid
  # Queue row, so the collectors never see it, nor any job it runs inline in
  # turn; Active Job's perform notification fires for each of them.
  def inline_performs(&)
    queues = []
    record = ->(*, payload) { queues << payload.fetch(:job).queue_name }
    ActiveSupport::Notifications.subscribed(record, "perform_start.active_job", &)
    queues.freeze
  end

  def control_failure(control, ran_ids)
    status = ran_ids.include?(control.active_job_id) ? "ran" : control.status
    return if status == UNRUN

    problem = status.nil? ? "was never checked" : status
    "control #{control.job_class} on #{control.queue} (active_job_id #{control.active_job_id}) #{problem}"
  end

  def execution_failure(record, dedicated_queues)
    return if dedicated_queues.fetch(record.database, []).include?(record.queue)

    "#{record.kind} execution of #{record.job_class} on non-dedicated queue #{record.queue} in #{record.database} " \
      "(job_id #{record.job_id}, active_job_id #{record.active_job_id})"
  end

  def ledger_shape?(document)
    document.is_a?(Hash) &&
      %w[records controls].all? { |key| document[key].is_a?(Array) && document[key].all?(Hash) }
  end

  def json_fields(value)
    value.to_h.transform_values { |field| field.respond_to?(:iso8601) ? field.utc.iso8601(6) : field }
  end

  # The same execution can be collected at more than one reset.
  def record_key(record)
    [record.database, record.kind, record.active_job_id, record.execution_id]
  end

  # A later check of the same control replaces the earlier one, except that a
  # recorded failure (ran or missing) is never overwritten: a control put back
  # after it went missing must still fail the run.
  def merge_controls(stored, added)
    by_id = stored.index_by(&:active_job_id)
    added.each do |control|
      earlier = by_id[control.active_job_id]
      by_id[control.active_job_id] = control unless earlier&.status && earlier.status != UNRUN
    end
    by_id.values
  end
  private_class_method :control_failure, :execution_failure, :ledger_shape?, :json_fields, :record_key,
                       :merge_controls
end

# Reads claimed, completed and failed executions on non-dedicated queues.
# Each collector selects named columns only, so job arguments and error text
# are never read.
module TimekeepingQueueLedger
  class CollectError < StandardError; end

  # Reads the monolith's Solid Queue tables through Active Record.
  module MonolithCollector
    DATABASE = "monolith"

    module_function

    def collect
      jobs = SolidQueue::Job.where.not(queue_name: DEDICATED_QUEUES.fetch(DATABASE))
      completed = jobs.where.not(finished_at: nil).map { |job| record(job, "completed", nil) }
      claimed = executions(SolidQueue::ClaimedExecution, jobs, "claimed")
      failed = executions(SolidQueue::FailedExecution, jobs, "failed")
      completed + claimed + failed
    end

    def executions(model, jobs, kind)
      model.where(job_id: jobs.select(:id)).includes(:job).map { |execution| record(execution.job, kind, execution.id) }
    end

    def record(job, kind, execution_id)
      Record.new(database: DATABASE, queue: job.queue_name, job_class: job.class_name, kind:, job_id: job.id,
                 active_job_id: job.active_job_id, execution_id:, created_at: job.created_at,
                 finished_at: job.finished_at)
    end
    private_class_method :executions, :record
  end

  # Reads the Timekeeping database's Solid Queue tables over its own
  # connection, because the monolith's Active Record does not reach it.
  module TimekeepingCollector
    DATABASE = "timekeeping"
    EXECUTIONS_SQL = <<~SQL
      SELECT 'completed' AS kind, jobs.queue_name, jobs.class_name, jobs.id AS job_id, jobs.active_job_id,
             NULL::bigint AS execution_id, jobs.created_at, jobs.finished_at
      FROM solid_queue_jobs jobs
      WHERE jobs.finished_at IS NOT NULL AND jobs.queue_name NOT IN (%<dedicated>s)
      UNION ALL
      SELECT 'claimed', jobs.queue_name, jobs.class_name, jobs.id, jobs.active_job_id, claimed.id,
             jobs.created_at, jobs.finished_at
      FROM solid_queue_claimed_executions claimed JOIN solid_queue_jobs jobs ON jobs.id = claimed.job_id
      WHERE jobs.queue_name NOT IN (%<dedicated>s)
      UNION ALL
      SELECT 'failed', jobs.queue_name, jobs.class_name, jobs.id, jobs.active_job_id, failed.id,
             jobs.created_at, jobs.finished_at
      FROM solid_queue_failed_executions failed JOIN solid_queue_jobs jobs ON jobs.id = failed.job_id
      WHERE jobs.queue_name NOT IN (%<dedicated>s)
    SQL

    module_function

    # A database that does not exist yet holds no executions, as
    # TimekeepingDatabaseReset also treats it. Every other failure raises, so
    # an unreadable database is never mistaken for a clean one. Errors name
    # only the database and drop their cause, which can carry the URL's host.
    def collect(env)
      url = env[TimekeepingDatabaseReset::DATABASE_URL_KEY].to_s
      if url.strip.empty?
        raise CollectError, "#{TimekeepingDatabaseReset::DATABASE_URL_KEY} must be set while the queue ledger is active"
      end

      name = TimekeepingDatabaseReset.database_name(url)
      connection = connect(url, name)
      return [] unless connection

      rows(connection).map { |row| record(row) }
    rescue PG::Error
      raise CollectError, "could not read Solid Queue executions from the Timekeeping database #{name.inspect}", cause: nil
    ensure
      connection&.close
    end

    def connect(url, name)
      PG.connect(url)
    rescue PG::ConnectionBad => e
      return nil if name && e.message.include?("database #{PG::Connection.quote_ident(name)} does not exist")

      raise CollectError, "could not connect to the Timekeeping database #{name.inspect}", cause: nil
    end

    def rows(connection)
      dedicated = DEDICATED_QUEUES.fetch(DATABASE).map { |queue| connection.escape_literal(queue) }.join(", ")
      connection.exec(format(EXECUTIONS_SQL, dedicated:)).to_a
    end

    def record(row)
      Record.new(database: DATABASE, queue: row.fetch("queue_name"), job_class: row.fetch("class_name"),
                 kind: row.fetch("kind"), job_id: Integer(row.fetch("job_id"), 10),
                 active_job_id: row.fetch("active_job_id"),
                 execution_id: row.fetch("execution_id") && Integer(row.fetch("execution_id"), 10),
                 created_at: row.fetch("created_at"), finished_at: row.fetch("finished_at"))
    end
    private_class_method :connect, :rows, :record
  end

  # Enqueues the two control jobs and reads back whether they still exist
  # and have not run. A control is looked up only by its own active_job_id,
  # so a job other code enqueued never stands in for it.
  module Controls
    # SyncStripeSubscriptionCompanyJob requires a company id. A control must
    # never run, so no real company is named.
    PLACEHOLDER_COMPANY_ID = 0

    module_function

    # Each job is enqueued on a connection of its own, so it commits even when
    # the calling example runs inside a transaction that is rolled back later.
    def enqueue
      Thread.new do
        Thread.current.report_on_exception = false
        SolidQueue::Record.connection_pool.with_connection do
          adapter = ActiveJob::QueueAdapters::SolidQueueAdapter.new
          [UpdateInvoiceStatusToOverdueJob.new, SyncStripeSubscriptionCompanyJob.new(PLACEHOLDER_COMPANY_ID)].map do |job|
            adapter.enqueue(job)
            Control.new(queue: job.queue_name, job_class: job.class.name, job_id: job.provider_job_id,
                        active_job_id: job.job_id, status: nil)
          end
        end
      end.value
    end

    def check(controls)
      controls.map { |control| control.with(status: status(control)) }
    end

    def status(control)
      job = SolidQueue::Job.find_by(active_job_id: control.active_job_id)
      return "missing" unless job
      return "ran" if job.finished_at ||
                      SolidQueue::ClaimedExecution.exists?(job_id: job.id) ||
                      SolidQueue::FailedExecution.exists?(job_id: job.id)

      UNRUN
    end
    private_class_method :status
  end

  class LiveRuntimeDuringReset < StandardError; end

  class RunFailed < StandardError; end

  # The side-effecting shell around the pure verdict: it remembers whether a
  # runtime has activated the ledger, which controls are open, and which
  # runtimes to stop at the end of the suite. Inactive, it does nothing, so a
  # suite that never starts the integrated runtime runs unchanged.
  class Session
    attr_reader :path, :env, :runtime_roots

    # collectors maps a database name to a callable that answers its records.
    # live answers whether a runtime this ledger registered still has a live
    # process group.
    def initialize(path:, collectors:, live:)
      @path = path
      @collectors = collectors
      @live = live
      @active = false
      @env = {}.freeze
      @runtime_roots = []
      @runtimes = []
      @open_controls = []
      @written = false
      @stop_errors = []
    end

    def active?
      @active
    end

    # Once active, the ledger stays active for the rest of the suite: every
    # later reset collects, and the end of the suite judges what it recorded.
    def activate!(env:)
      @env = env.to_h.freeze
      @active = true
      nil
    end

    # The runtime itself is kept only so the end of the suite can stop it.
    def register_runtime(root, runtime: nil)
      @runtime_roots |= [root]
      @runtimes |= [runtime] if runtime
      nil
    end

    # A window still open from an earlier runtime is checked first, so its
    # controls are never dropped unchecked.
    def open_window!
      close_window! if @open_controls.any?
      @open_controls = Controls.enqueue
      nil
    end

    # Records the controls' current status after the workers stop. The window
    # stays open: the next reset checks the controls again, so one deleted in
    # between is still seen as missing.
    def observe_controls!
      return nil unless active? && @open_controls.any?

      write_ledger(records: [], controls: Controls.check(@open_controls))
    end

    # Called from IntegratedRuntime#stop!, which often runs in an ensure while
    # a boot or example error is in flight. A ledger error raised there would
    # replace that error, so it is kept and reported by finish! instead.
    def after_stop!
      [step_error { collect! }, step_error { observe_controls! }].compact.each { |error| @stop_errors << error }
      nil
    end

    # The live check comes first: collecting or deleting beside a running
    # worker would race it.
    def before_reset!
      return nil unless active?
      raise LiveRuntimeDuringReset, "a demo runtime is still live; refusing to reset its databases" if @live.call

      collect!
      close_window!
    end

    def collect!
      return nil unless active?

      write_ledger(records: @collectors.flat_map { |_database, collector| collector.call }, controls: [])
    end

    # Runs every step even when an earlier one raises, so a runtime that fails
    # to stop never hides what the ledger recorded. The live check is not run
    # here: a runtime that failed to stop is reported through its stop error.
    def finish!
      return nil unless active?

      errors = @runtimes.map { |runtime| step_error { runtime.stop! } } + @stop_errors
      errors << step_error { collect! }
      errors << step_error { close_window! }
      failures = []
      errors << step_error { failures = verdict_failures }
      problems = errors.compact.map { |error| "#{error.class}: #{error.message}" } + failures
      raise RunFailed, "queue ledger #{path}:\n#{problems.join("\n")}" if problems.any?

      nil
    end

    private

      def close_window!
        return nil if @open_controls.empty?

        checked = Controls.check(@open_controls)
        @open_controls = []
        write_ledger(records: [], controls: checked)
      end

      def verdict_failures
        stored = TimekeepingQueueLedger.parse(File.read(path))
        TimekeepingQueueLedger.verdict(records: stored[:records], controls: stored[:controls],
                                       dedicated_queues: DEDICATED_QUEUES).failures
      end

      def step_error
        yield
        nil
      rescue StandardError => e
        e
      end

      # A file this session wrote that is gone now was deleted by someone
      # else, which would lose what it recorded.
      def write_ledger(records:, controls:)
        raise UnreadableLedger, "the queue ledger file disappeared during the run" if @written && !File.exist?(path)

        TimekeepingQueueLedger.write(path, records:, controls:)
        @written = true
        nil
      end
  end

  LEDGER_DIR = "tmp/timekeeping-integration"
  LEDGER_NAME = "queue_ledger"
  DEFAULT_PATH = "#{LEDGER_DIR}/#{LEDGER_NAME}.json".freeze
  PATH_KEY = "TIMEKEEPING_QUEUE_LEDGER_PATH"
  # An absolute directory that replaces Rails.root as the base of the default
  # per-process path, so a spec can exercise that naming in a private directory.
  ROOT_KEY = "TIMEKEEPING_QUEUE_LEDGER_ROOT"
  # parallel_tests gives its first process an empty number and the others "2", "3" and so on.
  PROCESS_NUMBER_KEY = "TEST_ENV_NUMBER"
  PROCESS_NUMBER = /\A[1-9]\d*\z/

  module_function

  # An explicit override is used exactly as written, so a spec that hands a
  # child process its own file reads back that same file. Otherwise every
  # parallel process gets its own default file, because each one deletes its
  # ledger at suite start. That default sits under ROOT_KEY when it is set,
  # otherwise under Rails.root.
  def ledger_path(env = ENV)
    override = env[PATH_KEY].to_s
    return override unless override.strip.empty?

    File.join(ledger_root(env[ROOT_KEY].to_s), default_ledger_file(env[PROCESS_NUMBER_KEY].to_s))
  end

  # The suite-start hook deletes a path under this root, so a relative root,
  # which would depend on the directory the process started in, is refused.
  def ledger_root(root)
    return Rails.root.to_s if root.strip.empty?
    raise ArgumentError, "#{ROOT_KEY} must be an absolute path, got #{root.inspect}" unless Pathname.new(root).absolute?

    root
  end

  # The number becomes part of a path the suite-start hook deletes, so anything
  # but a positive integer is refused rather than allowed to name another file.
  def default_ledger_file(process_number)
    return DEFAULT_PATH if process_number.empty?
    unless PROCESS_NUMBER.match?(process_number)
      raise ArgumentError, "#{PROCESS_NUMBER_KEY} must be empty or a positive integer, got #{process_number.inspect}"
    end

    File.join(LEDGER_DIR, "#{LEDGER_NAME}.#{process_number}.json")
  end

  # The process-wide session the cleaner hooks and the integrated runtime use.
  # Its collectors and live check read the session's own registered state.
  def build_session(env = ENV)
    session = nil
    collectors = {
      MonolithCollector::DATABASE => -> { MonolithCollector.collect },
      TimekeepingCollector::DATABASE => -> { TimekeepingCollector.collect(session.env) }
    }
    live = lambda do
      session.runtime_roots.any? do |root|
        IntegratedRuntime.recorded_groups(root).any? { |group| IntegratedRuntime.group_alive?(group) }
      end
    end
    session = Session.new(path: ledger_path(env), collectors:, live:)
  end

  SESSION = build_session

  def session
    SESSION
  end
end

RSpec.configure do |config|
  config.before(:suite) do
    FileUtils.rm_f(TimekeepingQueueLedger.session.path)
  end

  config.after(:suite) do
    TimekeepingQueueLedger.session.finish!
  end
end
