# frozen_string_literal: true

require "fileutils"
require "net/http"
require "tmpdir"

# Shared helpers for the live Timekeeping specs that run real handoffs against
# the demo runtime (spec/support/timekeeping/integrated_runtime.rb): relay
# pause and resume, per-run report roots, a setup cutover, a bounded catch-up,
# readers for money, receipts, queued counts and positions and the ownership
# row, and a teardown that puts the
# relay, ENV and the handoff integrations back however the example ended.
#
# The module functions take what they touch as arguments, so
# spec/meta/timekeeping_live_handoff_helpers_spec.rb proves them without a
# runtime. The shared context below wires them to @integrated_runtime.
module TimekeepingLiveHandoff
  # Timekeeping::TestHooks.relay_pause_file under the runtime's RAILS_ENV=test.
  PAUSE_FILE_PATH = "timekeeping/tmp/relay_paused.test"
  PAUSE_ROUTE = "/internal/v1/test-hooks/relay/pause"
  RESUME_ROUTE = "/internal/v1/test-hooks/relay/resume"
  HOOK_ANSWERED = "204"
  # Each drain request runs the relay synchronously inside Timekeeping, but
  # answers false whenever the runtime's own relay worker holds the relay lock,
  # even after that worker has sent every row. catch_up! therefore also reads
  # the unsent positions after each false answer, so a worker run that
  # delivered the rows counts as caught up. The count bounds only how long a
  # worker run still delivering can keep the lock: attempts run back to back,
  # with no wait, so a worker run longer than these attempts still fails the
  # catch-up, and its message says the lock may be the cause.
  CATCH_UP_ATTEMPTS = 30
  # Example metadata key holding every teardown step that raised and every
  # pause file found after an example.
  TEARDOWN_FAILURES_KEY = :live_handoff_teardown_failures
  REPORT_ROOT_PREFIX = "timekeeping-live-handoff"

  HookRefused = Class.new(StandardError)
  CatchUpIncomplete = Class.new(StandardError)
  TeardownFailed = Class.new(StandardError)
  NotLegacy = Class.new(StandardError)

  module_function

  def pause_file(root: Rails.root)
    Pathname(root).join(PAUSE_FILE_PATH)
  end

  # post: ->(route) { Net::HTTPResponse }, sending the service bearer token.
  def pause_relay(post:)
    require_hook_answer!(PAUSE_ROUTE, post.call(PAUSE_ROUTE))
  end

  # Deletes the pause file whatever the request did, so a resume request that
  # failed or raised still leaves the relay free to deliver. The request's
  # failure is still raised, so the teardown records it.
  def resume_relay(post:, pause_file:)
    require_hook_answer!(RESUME_ROUTE, post.call(RESUME_ROUTE))
  ensure
    FileUtils.rm_f(pause_file)
  end

  # Sends one POST to a Timekeeping route with the service bearer token and
  # answers the Net::HTTPResponse.
  def service_post(timekeeping_url:, service_token:, route:)
    uri = URI.join(timekeeping_url, route)
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{service_token}"
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
  end

  def require_hook_answer!(route, response)
    return nil if response.code == HOOK_ANSWERED

    raise HookRefused, "POST #{route} answered #{response.code}, expected #{HOOK_ANSWERED}"
  end

  # ownership: the stored row's columns as a Hash. A setup cutover must start
  # from the legacy state, or the example would prove a different handoff.
  def require_legacy_owner!(ownership)
    legacy = TimekeepingOwnerState.fetch("legacy").slice(:owner, :monolith_store, :legacy_retired_at)
    return nil if ownership.slice(*legacy.keys) == legacy

    raise NotLegacy, "a setup cutover starts from the legacy owner state, but the ownership row holds #{ownership.inspect}"
  end

  # drain: a Timekeeping::Handoff::RelayDrain. drain! returning says nothing,
  # because it returns without sending when it could not take the relay lock.
  # unsent_positions: ->(through:) { [Integer, ...] }, the outbox positions at
  # or below through with no sent_at: the same rows Timekeeping's drained?
  # checks after its relay run. An empty list means every row is sent.
  def catch_up!(drain:, through:, unsent_positions:, attempts: CATCH_UP_ATTEMPTS)
    unsent = []
    attempts.times do
      drain.drain!(through:)
      return nil if drain.drained?(through:)

      unsent = unsent_positions.call(through:)
      return nil if unsent.empty?
    end

    raise CatchUpIncomplete, "outbox positions #{unsent.inspect} at or below #{through} were still unsent after " \
                             "#{attempts} drain attempts; the runtime's relay worker may have held the relay lock"
  end

  # Runs the body, then every step in order. Each step runs even when the body
  # or an earlier step raised, and each step error is appended to failures.
  # When the body raised, its exception propagates unchanged, so a teardown
  # error never hides the real cause; the recorded failures are checked again
  # by assert_clean_teardowns!.
  def run_with_teardown(steps:, failures:)
    body_finished = false
    result = yield
    body_finished = true
    result
  ensure
    step_errors = run_steps(steps, failures)
    raise TeardownFailed, "teardown failed: #{step_errors.join('; ')}" if body_finished && step_errors.any?
  end

  def run_steps(steps, failures)
    steps.filter_map do |name, step|
      step.call
      nil
    rescue StandardError => error
      "#{name}: #{error.class}: #{error.message}".tap { |failure| failures << failure }
    end
  end

  # The live session: inside within_env the integrations are rebuilt and the
  # body runs; afterwards the relay is resumed, ENV is left, the integrations
  # are rebuilt from the restored ENV, and the report roots are removed.
  # within_env: ->(&block) { ... }, which sets ENV for the block and restores it.
  def run_session(failures:, within_env:, resume:, rebuild:, remove_report_roots:, &body)
    run_with_teardown(steps: { rebuild_integrations: rebuild, remove_report_roots: }, failures:) do
      within_env.call do
        run_with_teardown(steps: { resume_relay: resume }, failures:) do
          rebuild.call
          body.call
        end
      end
    end
  end

  # RSpec reports any failure in a pending example as the expected pending
  # failure, so a teardown failure there would pass silently. This check runs
  # in an after(:context) hook, where a failure fails the run whatever the
  # examples' status.
  def assert_clean_teardowns!(example_metadata)
    failures = example_metadata.flat_map do |metadata|
      metadata.fetch(TEARDOWN_FAILURES_KEY, []).map { |failure| "#{metadata[:full_description]}: #{failure}" }
    end
    raise TeardownFailed, "live handoff teardown failed:\n#{failures.join("\n")}" if failures.any?

    nil
  end

  def teardown_failures(metadata)
    metadata[TEARDOWN_FAILURES_KEY] ||= []
  end

  # Opens the Timekeeping database the runtime uses, after the same name guard
  # TenantStateDigest.timekeeping applies, and yields the PG connection.
  def with_timekeeping_database(env: ENV)
    url = env.fetch(TimekeepingDatabaseReset::DATABASE_URL_KEY)
    TestDatabaseGuard.require_test_database_url!(url)
    name = TimekeepingDatabaseReset.database_name(url)
    connection = TimekeepingDatabaseReset.connect(url, name)
    raise PG::ConnectionBad, "the Timekeeping database #{name.inspect} does not exist", cause: nil unless connection

    yield connection
  ensure
    connection&.close
  end

  def unsent_outbox_positions(connection, through:)
    connection.exec_params(
      "SELECT outbox_position FROM outbox_snapshots WHERE sent_at IS NULL AND outbox_position <= $1 " \
      "ORDER BY outbox_position",
      [Integer(through)]
    ).column_values(0).map { |position| Integer(position) }
  end

  # Unsent outbox snapshots of one company, or of one of its entries.
  def queued_count(connection, company_id:, entry_id: nil)
    sql = "SELECT count(*) FROM outbox_snapshots WHERE sent_at IS NULL AND company_id = $1"
    params = [Integer(company_id)]
    if entry_id
      sql += " AND id = $2"
      params << Integer(entry_id)
    end
    Integer(connection.exec_params(sql, params).getvalue(0, 0))
  end

  # Unsent outbox positions of one company, in order.
  def queued_positions(connection, company_id:)
    connection.exec_params(
      "SELECT outbox_position FROM outbox_snapshots WHERE sent_at IS NULL AND company_id = $1 ORDER BY outbox_position",
      [Integer(company_id)]
    ).column_values(0).map { |position| Integer(position) }
  end

  # receipts: EntrySnapshotReceipt-like objects answering id and response_body.
  # One receipt covers every company in its batch, so each receipt above the
  # baseline counts once; summing per company would count it twice.
  def applied_since(receipts, baseline_id:)
    receipts.select { |receipt| receipt.id > baseline_id }.each_with_object({ applied: 0, ignored: 0 }) do |receipt, sums|
      sums[:applied] += Integer(receipt.response_body.fetch("applied"))
      sums[:ignored] += Integer(receipt.response_body.fetch("ignored"))
    end
  end

  # The whole ownership row as JSON text, read through the raw connection so
  # Active Record's query cache cannot answer with an older row. Comparing the
  # text shows any column change.
  def ownership_row_text(connection)
    connection.exec("SELECT row_to_json(ownership)::text FROM timekeeping_ownership ownership").getvalue(0, 0)
  end

  # Idempotency receipts of one company, user and service receipts together.
  def receipt_count(connection, company_id:)
    Integer(connection.exec_params(<<~SQL.squish, [Integer(company_id)]).getvalue(0, 0))
      SELECT (SELECT count(*) FROM idempotency_receipts WHERE company_id = $1)
           + (SELECT count(*) FROM service_idempotency_receipts WHERE company_id = $1)
    SQL
  end

  # Uncached, because the runtime's processes write invoices through their
  # own connections, which do not clear this process's query cache.
  def money(company_id:)
    ActiveRecord::Base.uncached { Timekeeping::FinancialSnapshot.take(company_id:) }
  end
end

# Include in a live group that runs with :integrated_runtime. Call the
# example's steps inside with_live_handoff.
RSpec.shared_context "timekeeping live handoff" do
  # Only checks; deleting here would hide a teardown that left the file.
  after do |example|
    pause_file = TimekeepingLiveHandoff.pause_file
    if pause_file.exist?
      TimekeepingLiveHandoff.teardown_failures(example.metadata) << "#{TimekeepingLiveHandoff::PAUSE_FILE_PATH} survived the example"
    end
    expect(pause_file).not_to exist, "#{TimekeepingLiveHandoff::PAUSE_FILE_PATH} survived the example"
  end

  after(:context) do
    TimekeepingLiveHandoff.assert_clean_teardowns!(self.class.descendant_filtered_examples.map(&:metadata))
  end

  def with_live_handoff(&body)
    @live_handoff_report_roots = []
    live_env = {
      Timekeeping::EntryApiClient::BASE_URL_ENV => @integrated_runtime.timekeeping_url,
      Internal::V1::BaseController::SERVICE_TOKEN_ENV => @integrated_runtime.credentials.service_token
    }
    TimekeepingLiveHandoff.run_session(
      failures: TimekeepingLiveHandoff.teardown_failures(RSpec.current_example.metadata),
      within_env: ->(&block) { with_timekeeping_env(live_env, &block) },
      resume: -> { live_handoff_resume_relay },
      rebuild: -> { live_handoff_rebuild_integrations },
      remove_report_roots: -> { @live_handoff_report_roots.each { |root| FileUtils.rm_rf(root) } },
      &body
    )
  end

  def live_handoff_pause_relay
    TimekeepingLiveHandoff.pause_relay(post: method(:live_handoff_service_post))
  end

  def live_handoff_resume_relay
    TimekeepingLiveHandoff.resume_relay(post: method(:live_handoff_service_post),
                                        pause_file: TimekeepingLiveHandoff.pause_file)
  end

  def live_handoff_service_post(route)
    TimekeepingLiveHandoff.service_post(timekeeping_url: @integrated_runtime.timekeeping_url,
                                        service_token: @integrated_runtime.credentials.service_token, route:)
  end

  # Removed by the with_live_handoff teardown.
  def live_handoff_report_root
    Pathname(Dir.mktmpdir(TimekeepingLiveHandoff::REPORT_ROOT_PREFIX)).tap { |root| @live_handoff_report_roots << root }
  end

  # Reruns the initializer's own code, so the integrations read the URL and
  # token ENV holds now, as handoff_live_spec.rb does. Every other to_prepare
  # hook is left alone: rerunning them all reloads FactoryBot, which fails on
  # the seed's top-level helper methods.
  def live_handoff_rebuild_integrations
    allow(Rails.application.config).to receive(:to_prepare).and_yield
    load Rails.root.join("config/initializers/timekeeping_handoff.rb").to_s
  end

  # No owners: argument, so the run uses Runner.configured_owners.
  def live_handoff_cutover!
    ownership = TimekeepingOwnership.uncached do
      TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID)
                          .slice(:owner, :monolith_store, :legacy_retired_at).symbolize_keys
    end
    TimekeepingLiveHandoff.require_legacy_owner!(ownership)
    Timekeeping::Handoff::Runner.run(direction: :cutover, report_root: live_handoff_report_root)
  end

  # Drives the configured Timekeeping drain integration until every outbox
  # snapshot at or below through is sent. through defaults to Timekeeping's
  # highest outbox position now, so call it after the writes it must cover.
  # Returns through.
  def live_handoff_catch_up!(through: Timekeeping::Handoff::TimekeepingStore.new.highest_outbox_position)
    TimekeepingLiveHandoff.catch_up!(
      drain: Rails.configuration.x.timekeeping_handoff.timekeeping_drain,
      through:,
      unsent_positions: lambda { |through:|
        TimekeepingLiveHandoff.with_timekeeping_database do |connection|
          TimekeepingLiveHandoff.unsent_outbox_positions(connection, through:)
        end
      }
    )
    through
  end

  # An abort finishes only settle and freeze, so it writes no
  # reconciliation report. This runs the same checks the reconcile step runs
  # for a handoff out of Timekeeping: the outgoing owner's state now, and the
  # copy a resume would load, against the projection, the intents, and each
  # company's money compared with the money_before file the abort's settle
  # step stored under report_root. Returns the Reconciliation::Result.
  def live_handoff_aborted_reconciliation(report_root)
    handoff = Timekeeping::Handoff
    generation = TimekeepingOwnership.uncached { TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).generation }
    store = handoff::TimekeepingStore.new
    source = store.export_checkpoint
    loaded = handoff::ReservationLocks.build(source)
    ActiveRecord::Base.uncached do
      intents = handoff::RowReader.select_rows(InvoiceOperationsRecord.connection, handoff::Runner::INTENTS_SQL)
      # The same differences Runner#listed_corrections accepts: the locked
      # values the copy derives from reservations, and the receipts of
      # operations the legacy store committed before it was retired.
      legacy_receipts = handoff::LegacyOperationsCheck.listed_receipts(
        source_intents: intents, intents:, legacy_retired_at: TimekeepingOwnership.current.legacy_retired_at
      )
      listed_corrections = handoff::ReservationLocks.listed_corrections(source:, loaded:)
                                                   .merge(legacy_receipts) { |_company_id, locks, receipts| locks + receipts }
      handoff::Reconciliation.run(
        source:, checkpoint: loaded,
        projection: handoff::RowReader.select_rows(ActiveRecord::Base.connection, handoff::Runner::PROJECTION_SQL),
        source_intents: intents, intents:,
        next_entry_id: live_handoff_next_entry_id,
        money_before: handoff::ReportDirectory.new(root: report_root, generation:).read_money_before,
        money_after: Company.order(:id).pluck(:id).index_with { |id| TimekeepingLiveHandoff.money(company_id: id) },
        listed_corrections:
      )
    end
  end

  # The id Timekeeping's entry sequence hands out next, read without setval or
  # nextval: TimekeepingStore#advance_entry_id_sequence would raise a sequence
  # left behind by the abort before Reconciliation could report it.
  def live_handoff_next_entry_id
    TimekeepingLiveHandoff.with_timekeeping_database do |connection|
      sequence = connection.exec("SELECT pg_get_serial_sequence('entries', 'id')").getvalue(0, 0)
      quoted = connection.quote_ident(sequence.split(".", 2).map { |part| part.delete('"') })
      Integer(connection.exec("SELECT CASE WHEN is_called THEN last_value + 1 ELSE last_value END FROM #{quoted}")
                        .getvalue(0, 0))
    end
  end
end
