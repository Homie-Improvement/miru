# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "tmpdir"
# spec/rails_helper.rb requires support files in sorted order, and this file
# sorts before tenant_guard_cases.rb, whose frozen_copy the tables below use,
# and before timekeeping_database_reset.rb, which opens the Timekeeping database.
require_relative "tenant_guard_cases"
require_relative "timekeeping_database_reset"

# Shared support for the live handoff proofs: the replies each route counts as
# a refusal, the verdicts that judge a replay, a reconciliation report or a
# set of rows grouped by company, and the requests and replies those proofs
# send and compare.
#
# The judgements are pure: they take plain values and return a verdict or a
# list of failure messages, empty when the input passes. A failure message
# names only company ids and field names, never a request, a header or a URL,
# because these specs carry credentials and their messages end up in CI logs.
module LiveHandoff
  # One HTTP reply: its status and its body exactly as the server sent it.
  Reply = Data.define(:status, :body)

  # Each table holds the exact status and parsed body of every refusal a route
  # renders, so a reply counts as refused only when both match one entry.
  #
  # The Timekeeping entry API renders { reason: } with the status
  # Timekeeping::Reasons maps it to; key_reused comes from
  # contracts/timekeeping/idempotency.yml errors.key_reused.
  TIMEKEEPING_REFUSALS = TenantGuardCases.frozen_copy(
    [
      { status: 422, body: { "reason" => "idempotency_key_reused" } },
      { status: 409, body: { "reason" => "stale_generation" } }
    ]
  )

  # The monolith web and CLI routes share ErrorHandler
  # (app/controllers/concerns/error_handler.rb). A key reused for other request
  # values renders the rejected message with its reason. Its 404 is left out:
  # that body carries the record's own not-found message, so it is no fixed pair.
  MONOLITH_REFUSALS = TenantGuardCases.frozen_copy(
    [
      { status: 422, body: { "errors" => I18n.t("errors.entry_write_rejected") } },
      { status: 422, body: { "errors" => I18n.t("errors.entry_write_rejected"),
                             "reason" => Timekeeping::Gateway::KEY_REUSED_REASON } },
      { status: 409, body: { "errors" => I18n.t("errors.stale_generation"), "reason" => "stale_generation" } }
    ]
  )

  # A key or entry of another company is never found, so only a replay across
  # companies may count Timekeeping's 404 as a refusal.
  CROSS_COMPANY_REFUSALS = TenantGuardCases.frozen_copy(
    [*TIMEKEEPING_REFUSALS, { status: 404, body: { "reason" => "not_found" } }]
  )

  SUCCESS_STATUSES = (200..299)

  # Request headers that sign a monolith request in, downcased because header
  # names are case-insensitive. web_replay_request drops every one of them from
  # the recording, in any spelling, so a replay can only authenticate as the
  # company whose credentials it is given.
  CREDENTIAL_HEADERS = %w[authorization x-auth-email x-auth-token].freeze

  # Net::HTTP decompresses a gzip reply on its own; asking for identity keeps
  # the body as the bytes the server wrote.
  IDENTITY_ENCODING = { "Accept-Encoding" => "identity" }.freeze
  JSON_CONTENT_TYPE = { "Content-Type" => "application/json" }.freeze
  OPEN_TIMEOUT_SECONDS = 5
  READ_TIMEOUT_SECONDS = 30

  # One SQL statement per count, each bound to a single company id as $1, so
  # the counts of two companies are never added together. audits has no
  # company column: TimesheetEntry is audited with associated_with: :company,
  # so its rows name the company as their associated record.
  MONOLITH_COUNT_QUERIES = {
    timesheet_entries: "SELECT count(*) FROM timesheet_entries WHERE company_id = $1",
    entries: "SELECT count(*) FROM entries WHERE company_id = $1",
    entry_versions: "SELECT COALESCE(sum(version), 0) FROM entries WHERE company_id = $1",
    timesheet_entry_audits: "SELECT count(*) FROM audits WHERE auditable_type = 'TimesheetEntry' " \
                            "AND associated_type = 'Company' AND associated_id = $1",
    entry_audits: "SELECT count(*) FROM entry_audits WHERE company_id = $1",
    legacy_create_receipts: "SELECT count(*) FROM legacy_create_receipts WHERE company_id = $1",
    legacy_entry_write_receipts: "SELECT count(*) FROM legacy_entry_write_receipts WHERE company_id = $1",
    idempotency_records: "SELECT count(*) FROM idempotency_records WHERE company_id = $1",
    entry_snapshot_receipts: "SELECT count(*) FROM entry_snapshot_receipts WHERE $1 = ANY(company_ids)",
    entry_outbox_items: "SELECT count(*) FROM entry_outbox_items WHERE company_id = $1"
  }.freeze

  TIMEKEEPING_COUNT_QUERIES = {
    entries: "SELECT count(*) FROM entries WHERE company_id = $1",
    entry_versions: "SELECT COALESCE(sum(version), 0) FROM entries WHERE company_id = $1",
    audit_events: "SELECT count(*) FROM audit_events WHERE company_id = $1",
    idempotency_receipts: "SELECT count(*) FROM idempotency_receipts WHERE company_id = $1",
    service_idempotency_receipts: "SELECT count(*) FROM service_idempotency_receipts WHERE company_id = $1",
    outbox_snapshots: "SELECT count(*) FROM outbox_snapshots WHERE company_id = $1"
  }.freeze

  module_function

  # Per-company counts in both stores: { monolith: {...}, timekeeping: {...} }.
  def tenant_counts(company_id:, env: ENV)
    { monolith: monolith_counts(company_id:), timekeeping: timekeeping_counts(company_id:, env:) }
  end

  # Read uncached: a write through another connection does not clear Active
  # Record's query cache, so a cached count would hide it.
  def monolith_counts(company_id:)
    connection = ActiveRecord::Base.connection
    ActiveRecord::Base.uncached do
      MONOLITH_COUNT_QUERIES.transform_values do |sql|
        connection.select_value(sql, "LiveHandoff", [company_id]).to_i
      end
    end
  end

  # Opens the database ENV[TimekeepingDatabaseReset::DATABASE_URL_KEY] names,
  # after checking that both readings of the URL name a _test database. A
  # missing database raises rather than counting as empty, and no error
  # carries the URL.
  def timekeeping_counts(company_id:, env: ENV)
    url = env.fetch(TimekeepingDatabaseReset::DATABASE_URL_KEY)
    TestDatabaseGuard.require_test_database_url!(url)
    name = TimekeepingDatabaseReset.database_name(url)
    connection = TimekeepingDatabaseReset.connect(url, name)
    raise PG::ConnectionBad, "the Timekeeping database #{name.inspect} does not exist", cause: nil unless connection

    TIMEKEEPING_COUNT_QUERIES.transform_values do |sql|
      connection.exec_params(sql, [company_id]).getvalue(0, 0).to_i
    end
  ensure
    connection&.close
  end

  # :answered_from_receipt for a 2xx reply whose bytes equal the stored
  # receipt's, :refused for a reply whose status and parsed body equal one
  # entry of refusals, :failed for anything else. A replay that executed again
  # answers 2xx with new bytes, so it fails.
  def replay_verdict(status:, body:, expected_body:, refusals:)
    return :answered_from_receipt if SUCCESS_STATUSES.cover?(status) && body.b == expected_body.b
    return :refused if refusals.include?({ status:, body: parsed_json(body) })

    :failed
  end

  # Failure messages for a reconciliation.json report, empty when the report
  # names exactly company_ids, each with abort false and unlisted empty, and
  # has no unassigned rows. Every field must hold exactly that value, so a
  # missing or null field fails as well.
  def reconciliation_failures(report_hash, company_ids:)
    companies = report_hash.fetch("companies", nil)
    return ["the report lists no companies"] unless companies.is_a?(Hash)

    failures = []
    failures << "the report's abort is not false" unless report_hash["abort"] == false
    failures << "the report's unassigned is not empty" unless report_hash["unassigned"] == []
    listed_ids = companies.keys.filter_map { |key| Integer(key.to_s, 10, exception: false) }
    unless listed_ids.size == companies.size && listed_ids.sort == company_ids.sort
      failures << "the report lists companies #{listed_ids.sort} instead of #{company_ids.sort}"
    end
    companies.each do |key, company|
      failures.concat(company_report_failures(key, company))
    end
    failures
  end

  # Failure messages for rows grouped by the company they were read for,
  # { company_id => [{ "company_id" => id } or { "company_ids" => [ids] }] },
  # empty when every company in company_ids has rows and every row names its
  # own company and no other. A company with no row of its own fails, so the
  # check can never pass on rows it did not see.
  def foreign_id_failures(rows_by_company, company_ids:)
    company_ids.flat_map do |company_id|
      rows = rows_by_company.fetch(company_id, [])
      next ["company #{company_id} has no rows of its own"] if rows.empty?

      rows.each_with_index.filter_map do |row, index|
        named = named_companies(row)
        next if named == [company_id]

        "company #{company_id} row #{index} names companies #{named.inspect}"
      end
    end
  end

  # The body the web controller renders for a create or update, rebuilt from
  # the entry columns a receipt stored. The entry is instantiated from those
  # columns, as the gateway's own legacy replay does, so a later edit to the
  # live row never reaches the expected reply.
  def expected_web_reply(receipt_entry_attributes, action:)
    entry = TimesheetEntry.instantiate(receipt_entry_attributes).tap(&:readonly!)
    { notice: I18n.t("timesheet_entry.#{action}.message"), entry: entry.snippet }.to_json
  end

  # The same reply built from an entry row an owner stored in its receipt
  # (Timekeeping's idempotency_receipts or the prepared store's
  # idempotency_records), hydrated as the gateway hydrates an owner's answer.
  # A row the company would not render, such as one of another company, raises.
  def expected_web_reply_from_row(row, company:, action:)
    entry = Timekeeping::EntryReader.hydrate([row], company:, user_id: row["user_id"]).first
    raise ArgumentError, "the stored row is not an entry of company #{company.id}" if entry.nil?

    { notice: I18n.t("timesheet_entry.#{action}.message"), entry: entry.snippet }.to_json
  end

  # The refusals of company A's replay of company B's web create. The
  # controller looks the recorded project up inside A's company before any
  # receipt is read, so A is refused with ErrorHandler's 404 and the
  # not-found message of that lookup, which the caller reads by running the
  # same scoped find. Only that exact pair is added to the monolith refusals.
  def cross_company_web_refusals(not_found_message:)
    TenantGuardCases.frozen_copy([*MONOLITH_REFUSALS, { status: 404, body: { "errors" => not_found_message } }])
  end

  # The recorded web request sent again with another company's credentials:
  # path, Idempotency-Key and body as recorded, the recording's credential
  # headers dropped, and X-Auth-Email and X-Auth-Token set to the ones given.
  # Web paths name no company, so company_id is not written into the request.
  def web_replay_request(recorded, company_id:, auth_email:, auth_token:) # rubocop:disable Lint/UnusedMethodArgument
    headers = recorded.fetch(:headers).reject { |name, _value| CREDENTIAL_HEADERS.include?(name.to_s.downcase) }
                      .merge("X-Auth-Email" => auth_email, "X-Auth-Token" => auth_token)
    TenantGuardCases.frozen_copy(recorded.merge(headers:))
  end

  # Sends one request of the TenantGuardCases shape { method:, path:, headers:, body: }
  # once, with no retry, and returns its status and raw body bytes. A Hash body
  # is sent as JSON. A failure names only the method and path, because the
  # headers can carry a token.
  def send_request(base_url, request)
    uri = URI.join(base_url, request.fetch(:path))
    http_request = build_http_request(uri, request)
    response = Net::HTTP.start(uri.host, uri.port, open_timeout: OPEN_TIMEOUT_SECONDS,
                                                   read_timeout: READ_TIMEOUT_SECONDS) do |http|
      # Net::HTTP resends an idempotent request (GET, PUT, DELETE) once when
      # the connection drops; a replay proof must see exactly one attempt.
      http.max_retries = 0
      http.request(http_request)
    end
    Reply.new(status: Integer(response.code, 10), body: response.body.to_s.b)
  rescue SystemCallError, IOError, Net::ProtocolError, Timeout::Error => e
    raise e.class, "#{request.fetch(:method)} #{request.fetch(:path)} could not be sent", cause: nil
  end

  def company_report_failures(key, company)
    return ["company #{key} has no report"] unless company.is_a?(Hash)

    failures = []
    failures << "company #{key} abort is not false" unless company["abort"] == false
    failures << "company #{key} unlisted is not empty" unless company["unlisted"] == []
    failures
  end

  def named_companies(row)
    return [row["company_id"]] if row.key?("company_id")

    Array(row["company_ids"]).uniq
  end

  # nil for a body that is not a JSON object, so it matches no refusal.
  def parsed_json(body)
    parsed = JSON.parse(body)
    parsed.is_a?(Hash) ? parsed : nil
  rescue JSON::ParserError
    nil
  end

  def build_http_request(uri, request)
    method = request.fetch(:method).to_s.capitalize
    http_request = Net::HTTP.const_get(method).new(uri)
    body = request[:body]
    headers = IDENTITY_ENCODING.merge(body.is_a?(Hash) ? JSON_CONTENT_TYPE : {}).merge(request.fetch(:headers, {}))
    headers.each { |name, value| http_request[name] = value }
    http_request.body = body.is_a?(Hash) ? JSON.generate(body) : body unless body.nil?
    http_request
  end
  private_class_method :company_report_failures, :named_companies, :parsed_json, :build_http_request

  # Drives real handoffs from an :integrated_runtime example against the
  # runtime the example started, with the owners
  # config/initializers/timekeeping_handoff.rb configures.
  module ExampleHelpers
    EXPECTED_OWNER = { cutover: "timekeeping", rollback: "monolith", re_cutover: "timekeeping" }.freeze
    HANDOFF_INITIALIZER = "config/initializers/timekeeping_handoff.rb"

    # The initializer reads the Timekeeping URL and tokens from ENV when it
    # runs, so it runs again with the runtime's values and, once ENV is put
    # back, again on every way out, a raising handoff included. Otherwise later
    # examples would talk to a stopped runtime with its token.
    def with_live_handoff_integrations(runtime, rebuild: method(:rebuild_live_handoff_integrations))
      live_env = {
        Timekeeping::EntryApiClient::BASE_URL_ENV => runtime.timekeeping_url,
        Internal::V1::BaseController::SERVICE_TOKEN_ENV => runtime.credentials.service_token,
        Timekeeping::UserToken::PRIVATE_KEY_ENV => runtime.credentials.private_key_pem
      }
      with_timekeeping_env(live_env) do
        rebuild.call
        yield
      end
    ensure
      rebuild.call
    end

    # Runs one handoff with the configured owners, asserts the stored
    # ownership row moved to the direction's owner at a higher generation with
    # no step left, and requires a clean reconciliation report for exactly
    # company_ids. Returns the parsed report.
    def run_live_handoff(direction, company_ids:)
      owner_before, generation_before, = live_handoff_ownership_row
      report_root = Pathname(Dir.mktmpdir("timekeeping-live-handoff"))

      # No owners: argument, so the run uses Runner.configured_owners.
      Timekeeping::Handoff::Runner.run(direction:, report_root:)

      owner, generation, handoff_step = live_handoff_ownership_row
      expect(owner).to eq(EXPECTED_OWNER.fetch(direction))
      expect(owner).not_to eq(owner_before)
      expect(generation).to be > generation_before
      expect(handoff_step).to be_nil
      report = JSON.parse(File.read(report_root.join("generation-#{generation}", "reconciliation.json")))
      expect(LiveHandoff.reconciliation_failures(report, company_ids:)).to eq([])
      report
    ensure
      FileUtils.rm_rf(report_root) if report_root
    end

    private

      # Every other to_prepare hook is left alone: rerunning them all reloads
      # FactoryBot, which fails on the seed's top-level helper methods.
      def rebuild_live_handoff_integrations
        allow(Rails.application.config).to receive(:to_prepare).and_yield
        load Rails.root.join(HANDOFF_INITIALIZER).to_s
      end

      def live_handoff_ownership_row
        TimekeepingOwnership.uncached do
          TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID).pick(:owner, :generation, :handoff_step)
        end
      end
  end
end

RSpec.configure do |config|
  config.include LiveHandoff::ExampleHelpers, :integrated_runtime
end
