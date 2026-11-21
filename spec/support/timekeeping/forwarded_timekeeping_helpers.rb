# frozen_string_literal: true

# The address forwarded specs route to their FakeTimekeeping. Top level so an
# example body can read it as well as the helpers below.
FORWARDED_TIMEKEEPING_BASE_URL = "http://timekeeping.test"

# Setup for specs whose entry writes are forwarded to a FakeTimekeeping instead
# of the legacy store. Local employments and roles stay with each spec, because
# they differ from one group to the next.
module TimekeepingForwardingHelpers
  # Puts the ownership row and the fake in owner_state, registers the company,
  # each user with its role and the project on the fake, and routes HTTP for
  # base_url to it. users maps a user to its role. owner_state defaults to the
  # state selected for the run, so a regression run proves the state it
  # selected; with no state selected, the row is put in the timekeeping state,
  # which gives Timekeeping ownership at generation 2 on both sides.
  #
  # While TimekeepingRegressionAdapter runs, the live app owns the connection:
  # only the ownership row is written, and the fake is never called, so a spec
  # cannot pass while its requests or generation silently reach the fake.
  def arrange_forwarded_timekeeping(fake, company:, users:, project:, base_url: FORWARDED_TIMEKEEPING_BASE_URL,
                                    owner_state: TimekeepingOwnerState::SELECTED)
    state_name = owner_state || "timekeeping"
    TimekeepingOwnerState.apply!(state_name)
    return if TimekeepingRegressionAdapter.current

    fake.generation = TimekeepingOwnerState.fetch(state_name).fetch(:generation)
    fake.register_company(id: company.id, edit_days: company.timesheet_edit_days)
    users.each { |user, role| fake.register_user(id: user.id, company_id: company.id, role:) }
    fake.register_project(id: project.id, company_id: company.id)
    route_timekeeping_to_fake(fake, base_url:)
  end

  # The Idempotency-Key header of a request the fake recorded, matched without
  # regard to case because the HTTP client may send the name in any case.
  def forwarded_idempotency_key(request)
    request.fetch(:headers).find { |key, _value| key.to_s.casecmp?("Idempotency-Key") }&.last
  end

  # Every request the monolith sent to Timekeeping, in send order, as
  # { method:, idempotency_key:, body: }. Read from the fake's own request
  # list, or, while TimekeepingRegressionAdapter runs, from the requests the
  # monolith sent to the live app, because the live app keeps no request log.
  # No path is filtered out, so an exact check on this list also fails when an
  # extra request of any kind is sent.
  def forwarded_timekeeping_requests(fake)
    return ForwardedTimekeepingRequestLog.requests if TimekeepingRegressionAdapter.current

    fake.requests.map do |request|
      { method: request.fetch(:method), idempotency_key: forwarded_idempotency_key(request), body: request.fetch(:body) }
    end
  end

  # The POST requests among forwarded_timekeeping_requests, in send order.
  def forwarded_create_requests(fake)
    forwarded_timekeeping_requests(fake).select { |request| request.fetch(:method) == "POST" }
  end

  # How many entries Timekeeping has ever stored, discarded ones included: the
  # distinct entry ids in the fake's outbox, or, while
  # TimekeepingRegressionAdapter runs, the live entries rows for company. A
  # duplicate write therefore shows up as an extra entry even if it was later
  # discarded.
  def forwarded_stored_entry_count(fake, company:)
    if TimekeepingRegressionAdapter.current
      return with_live_timekeeping_database do |connection|
        connection.exec_params("SELECT count(*) FROM entries WHERE company_id = $1", [company.id]).getvalue(0, 0).to_i
      end
    end

    fake.outbox.map { |row| row.fetch("entry").fetch("id") }.uniq.size
  end

  # Moves the generation Timekeeping admits writes at: on the fake, or, while
  # TimekeepingRegressionAdapter runs, in the live admission row only, so the
  # fake is never called while the live app owns the connection. The live
  # database is reset to the state's generation before every example, so the
  # change ends with the example. After that reset no settle step or held
  # generation is open, so this update matches Timekeeping::Admission.admit!.
  def admit_forwarded_generation(fake, generation)
    unless TimekeepingRegressionAdapter.current
      fake.generation = generation
      return
    end

    with_live_timekeeping_database do |connection|
      result = connection.exec_params("UPDATE admission SET generation = $1 WHERE id = $2",
                                      [generation, TimekeepingDatabaseReset::ADMISSION_ID])
      # A missing admission row would leave the generation unchanged, and the
      # example would then fail later on a stale-generation refusal instead.
      raise "the live admission row #{TimekeepingDatabaseReset::ADMISSION_ID} is missing" unless result.cmd_tuples == 1
    end
  end

  # Sets the Timekeeping base URL and the user token signing key for the block,
  # so the importer forwards its writes, and puts both back afterwards. While
  # TimekeepingRegressionAdapter runs, its URL and key are used instead, even
  # over an explicit base_url, because the live app alone owns the connection.
  def with_forwarded_timekeeping_env(base_url = FORWARDED_TIMEKEEPING_BASE_URL, &block)
    live = TimekeepingRegressionAdapter.current
    with_timekeeping_env(
      {
        Timekeeping::EntryApiClient::BASE_URL_ENV => live ? live.base_url : base_url,
        Timekeeping::UserToken::PRIVATE_KEY_ENV => (live ? live.private_key : timekeeping_key_pair).to_pem
      },
      &block
    )
  end

  private

    # The adapter refused to start unless its URL names a test database, so
    # no other database can be read or written here. The URL is the one the
    # running adapter checked, not a fresh read of the environment.
    def with_live_timekeeping_database
      connection = PG.connect(TimekeepingRegressionAdapter.database_url)
      yield connection
    ensure
      connection&.close
    end
end

# The requests the monolith sent to the live Timekeeping app during the
# current example. A WebMock callback records them, because the live app keeps
# no request log and its idempotency receipts hold one row per key, so neither
# can show that a key was sent twice or in what order. WebMock.reset! between
# examples leaves callbacks in place; the before hook below empties the log.
module ForwardedTimekeepingRequestLog
  IDEMPOTENCY_KEY_HEADER = "Idempotency-Key"

  @requests = []

  class << self
    def requests
      @requests.dup
    end

    def clear
      @requests = []
    end

    # Records request_signature when it went to the running live app's host
    # and port, whatever its path; requests to any other address are left out.
    def record(request_signature)
      live = TimekeepingRegressionAdapter.current
      return unless live

      uri = request_signature.uri
      live_uri = URI(live.base_url)
      return unless uri.host == live_uri.host && uri.inferred_port == live_uri.port

      @requests += [{
        method: request_signature.method.to_s.upcase,
        idempotency_key: header(request_signature, IDEMPOTENCY_KEY_HEADER),
        body: request_signature.body.to_s.empty? ? {} : JSON.parse(request_signature.body)
      }]
    end

    private

      def header(request_signature, name)
        request_signature.headers.to_h.find { |key, _value| key.to_s.casecmp?(name) }&.last
      end
  end
end

WebMock.after_request { |request_signature, _response| ForwardedTimekeepingRequestLog.record(request_signature) }

RSpec.configure do |config|
  config.include TimekeepingForwardingHelpers
  config.before { ForwardedTimekeepingRequestLog.clear }
end
