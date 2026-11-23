# frozen_string_literal: true

require "fileutils"
require "net/http"
require "tmpdir"

# Shared helpers for the live Timekeeping specs that run real handoffs against
# the demo runtime (spec/support/timekeeping/integrated_runtime.rb): relay
# pause and resume, per-run report roots, a setup cutover, a bounded catch-up,
# readers for money, receipts, queued snapshots, ownership and projection
# state, a rebuild of the batches the relay posted, and a teardown that puts the
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

  # Unsent outbox positions of one company, in order.
  def queued_positions(connection, company_id:)
    connection.exec_params(
      "SELECT outbox_position FROM outbox_snapshots WHERE sent_at IS NULL AND company_id = $1 ORDER BY outbox_position",
      [Integer(company_id)]
    ).column_values(0).map { |position| Integer(position) }
  end

  # Every outbox row of one company as the database's own row_to_json text,
  # sent_at included, in position order.
  def outbox_rows_text(connection, company_id:)
    connection.exec_params(
      "SELECT row_to_json(t)::text FROM outbox_snapshots t WHERE company_id = $1 ORDER BY outbox_position",
      [Integer(company_id)]
    ).column_values(0)
  end

  # Timekeeping's admission row as row_to_json text.
  def admission_text(connection)
    connection.exec("SELECT row_to_json(t)::text FROM admission t ORDER BY id").column_values(0)
  end

  # The ownership row as row_to_json text, read past the query cache because
  # the runner and the runtime write it through other connections.
  def ownership_row_text
    connection = ActiveRecord::Base.connection
    ActiveRecord::Base.uncached do
      connection.select_value(
        "SELECT row_to_json(t)::text FROM #{connection.quote_table_name(TimekeepingOwnership.table_name)} t " \
        "WHERE id = #{Integer(TimekeepingOwnership::SINGLETON_ID)}"
      )
    end
  end

  # One company's projection rows as row_to_json text, in id order, uncached.
  def projection_rows_text(company_id:)
    connection = ActiveRecord::Base.connection
    ActiveRecord::Base.uncached do
      connection.select_values(
        "SELECT row_to_json(t)::text FROM timesheet_entries t WHERE company_id = $1 ORDER BY id",
        "TimekeepingLiveHandoff", [Integer(company_id)]
      )
    end
  end

  # Every entry snapshot receipt as row_to_json text, in id order, uncached.
  def snapshot_receipts_text
    ActiveRecord::Base.uncached do
      ActiveRecord::Base.connection.select_values(
        "SELECT row_to_json(t)::text FROM #{EntrySnapshotReceipt.quoted_table_name} t ORDER BY id"
      )
    end
  end

  # The highest entry snapshot receipt id now, 0 when there is none. Take it
  # before the run that delivers the measured snapshots.
  def snapshot_receipt_baseline
    ActiveRecord::Base.uncached { EntrySnapshotReceipt.maximum(:id) || 0 }
  end

  SnapshotReceipt = Data.define(:id, :key, :applied)

  # The receipts written after baseline_id, in id order. One receipt covers
  # every company in its batch, so each one is listed once.
  def snapshot_receipts_after(baseline_id)
    ActiveRecord::Base.uncached do
      EntrySnapshotReceipt.where(id: (Integer(baseline_id) + 1)..).order(:id).map do |receipt|
        SnapshotReceipt.new(id: receipt.id, key: receipt.key, applied: Integer(receipt.response_body.fetch("applied")))
      end
    end
  end

  # The sum of applied over the receipts written after baseline_id. A snapshot
  # applied twice, or skipped, moves this sum away from the queued count.
  def applied_after(baseline_id)
    snapshot_receipts_after(baseline_id).sum(&:applied)
  end

  # Everything "a second resume changes nothing" compares, as text or plain
  # values, for the given companies. timekeeping_connection reads Timekeeping's
  # outbox and admission.
  def state_snapshot(timekeeping_connection, company_ids:)
    {
      ownership: ownership_row_text,
      admission: admission_text(timekeeping_connection),
      receipts: snapshot_receipts_text,
      companies: company_ids.to_h do |company_id|
        [company_id, { projection: projection_rows_text(company_id:),
                       outbox: outbox_rows_text(timekeeping_connection, company_id:),
                       money: money(company_id:) }]
      end
    }
  end

  # TenantStateDigest.take for one company, given the Timekeeping database
  # URL from env, never the runtime's HTTP address.
  def tenant_digest(company_id:, env: ENV)
    TenantStateDigest.take(company_id:, timekeeping_url: env.fetch(TimekeepingDatabaseReset::DATABASE_URL_KEY))
  end

  # The most rows one relay POST carries: RelayJob::BATCH_SIZE in
  # timekeeping/app/jobs/relay_job.rb, which this process does not load.
  RELAY_BATCH_SIZE = 100
  # outbox_snapshots columns the relay sends as Integers, Floats, booleans,
  # ISO 8601 times or exact JSON; every other entry field is sent as stored
  # text (work_date as its ISO date text, which JSON writes as a Date is).
  RELAY_INTEGER_FIELDS = %w[id project_id user_id agent_id company_id version].freeze
  RELAY_FLOAT_FIELDS = %w[duration].freeze
  RELAY_BOOLEAN_FIELDS = %w[locked].freeze
  RELAY_TIME_FIELDS = %w[discarded_at created_at updated_at].freeze
  RELAY_JSON_FIELDS = %w[source_metadata proof_metadata].freeze
  RELAY_STORED_TRUE = "t"

  RelayBatch = Data.define(:body, :idempotency_key)

  # The outbox rows at the given positions, each column as the database's
  # text, in position order.
  def outbox_relay_rows(connection, positions:)
    columns = (Timekeeping::SnapshotBatch::ENTRY_FIELDS + %w[generation outbox_position])
              .map { |column| connection.quote_ident(column) }.join(", ")
    result = connection.exec_params(
      "SELECT #{columns} FROM outbox_snapshots WHERE outbox_position = ANY($1::bigint[]) ORDER BY outbox_position",
      [PG::TextEncoder::Array.new.encode(positions.map { |position| Integer(position) })]
    )
    result.to_a
  end

  # The batches the relay posts for these rows, built as
  # Timekeeping::RelayOutboxSource#relay_row and TimekeepingRelay::Relay
  # build them, so the body and Idempotency-Key match a delivery the
  # projection already answered.
  def relay_batches(rows)
    rows.each_slice(RELAY_BATCH_SIZE).map do |slice|
      batch = TimekeepingRelay::BatchJson.canonical(
        "schema_version" => TimekeepingRelay::Relay::SCHEMA_VERSION,
        "snapshots" => slice.map { |row| relay_snapshot(row) }
      )
      RelayBatch.new(body: TimekeepingRelay::BatchJson.generate(batch),
                     idempotency_key: TimekeepingRelay::IdempotencyKey.for(batch))
    end
  end

  def relay_snapshot(row)
    {
      "generation" => Integer(row.fetch("generation")),
      "outbox_position" => Integer(row.fetch("outbox_position")),
      "entry" => Timekeeping::SnapshotBatch::ENTRY_FIELDS.to_h { |field| [field, relay_value(field, row.fetch(field))] }
    }
  end

  def relay_value(field, text)
    return nil if text.nil?

    case field
    when *RELAY_INTEGER_FIELDS then Integer(text)
    when *RELAY_FLOAT_FIELDS then Float(text)
    when *RELAY_BOOLEAN_FIELDS then text == RELAY_STORED_TRUE
    when *RELAY_TIME_FIELDS then Time.find_zone!("UTC").parse(text).utc.iso8601(6)
    when *RELAY_JSON_FIELDS then JSON.parse(text, decimal_class: BigDecimal)
    else text
    end
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
    uri = URI.join(@integrated_runtime.timekeeping_url, route)
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{@integrated_runtime.credentials.service_token}"
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
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
end
