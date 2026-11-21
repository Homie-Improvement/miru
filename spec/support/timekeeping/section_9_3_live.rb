# frozen_string_literal: true

require "fileutils"
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
# child's output: the environment holds the runtime's private key, a URL can
# hold a password, and these errors end up in CI logs.
module TimekeepingSection93Live
  class CutoverAborted < StandardError; end
  class TimekeepingReadError < StandardError; end
  class PollTimeout < StandardError; end

  HANDOFF_INITIALIZER = "config/initializers/timekeeping_handoff.rb"
  DEFAULT_POLL_SECONDS = 30
  POLL_INTERVAL_SECONDS = 0.1

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

  private

    # Reruns only the handoff initializer's own to_prepare block. Rerunning
    # every to_prepare hook reloads FactoryBot, which fails on the seed's
    # top-level helper methods.
    def section_9_3_rebuild_handoff_integrations
      allow(Rails.application.config).to receive(:to_prepare).and_yield
      load Rails.root.join(HANDOFF_INITIALIZER).to_s
    end

    # Opens a short-lived connection for one read-only query and answers its
    # rows with symbol keys and decoded column types. A connection or query
    # error is replaced by one that names only what was being read, because the
    # original can carry the URL's host or password.
    def section_9_3_timekeeping_rows(purpose, sql, params)
      url = ENV.fetch(TimekeepingDatabaseReset::DATABASE_URL_KEY) do
        raise TimekeepingReadError, "#{TimekeepingDatabaseReset::DATABASE_URL_KEY} is not set; cannot read #{purpose}"
      end
      TestDatabaseGuard.require_test_database_url!(url)
      begin
        connection = PG.connect(url)
        connection.type_map_for_results = PG::BasicTypeMapForResults.new(connection)
        connection.exec_params(sql, params).map { |row| row.transform_keys(&:to_sym) }
      rescue PG::Error
        raise TimekeepingReadError, "could not read #{purpose} from the Timekeeping database", cause: nil
      ensure
        connection&.close
      end
    end
end

RSpec.configure do |config|
  config.include TimekeepingSection93Live, integrated_runtime: true
end
