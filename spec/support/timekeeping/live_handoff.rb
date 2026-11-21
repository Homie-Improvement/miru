# frozen_string_literal: true

require "json"
require "net/http"
# spec/rails_helper.rb requires support files in sorted order, and this file
# sorts before tenant_guard_cases.rb, whose frozen_copy the tables below use.
require_relative "tenant_guard_cases"

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
  # (app/controllers/concerns/error_handler.rb). Its 404 is left out: that body
  # carries the record's own not-found message, so it is no fixed pair.
  MONOLITH_REFUSALS = TenantGuardCases.frozen_copy(
    [
      { status: 422, body: { "errors" => I18n.t("errors.entry_write_rejected") } },
      { status: 409, body: { "errors" => I18n.t("errors.stale_generation"), "reason" => "stale_generation" } }
    ]
  )

  # A key or entry of another company is never found, so only a replay across
  # companies may count Timekeeping's 404 as a refusal.
  CROSS_COMPANY_REFUSALS = TenantGuardCases.frozen_copy(
    [*TIMEKEEPING_REFUSALS, { status: 404, body: { "reason" => "not_found" } }]
  )

  SUCCESS_STATUSES = (200..299)

  # Request headers that sign a monolith request in. web_replay_request drops
  # every one of them from the recording, so a replay can only authenticate as
  # the company whose credentials it is given.
  CREDENTIAL_HEADERS = %w[Authorization X-Auth-Email X-Auth-Token].freeze

  # Net::HTTP decompresses a gzip reply on its own; asking for identity keeps
  # the body as the bytes the server wrote.
  IDENTITY_ENCODING = { "Accept-Encoding" => "identity" }.freeze
  JSON_CONTENT_TYPE = { "Content-Type" => "application/json" }.freeze
  OPEN_TIMEOUT_SECONDS = 5
  READ_TIMEOUT_SECONDS = 30

  module_function

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

  # The recorded web request sent again with another company's credentials:
  # path, Idempotency-Key and body as recorded, the recording's credential
  # headers dropped, and X-Auth-Email and X-Auth-Token set to the ones given.
  # Web paths name no company, so company_id is not written into the request.
  def web_replay_request(recorded, company_id:, auth_email:, auth_token:) # rubocop:disable Lint/UnusedMethodArgument
    headers = recorded.fetch(:headers).except(*CREDENTIAL_HEADERS)
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
end
