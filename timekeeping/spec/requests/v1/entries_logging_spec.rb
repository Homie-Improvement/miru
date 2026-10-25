# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Timekeeping entry reads: request logging" do
  let(:company_a) { 1 }
  let(:service_token) { SecureRandom.hex(32) }
  let(:token) { mint_token({ sub: 7, company_id: company_a, role: "owner" }) }

  around do |example|
    with_timekeeping_env(
      Timekeeping::Environment::TOKEN_PUBLIC_KEY => rsa_key_pair.public_key.to_pem,
      Timekeeping::Environment::SERVICE_TOKEN => service_token
    ) { example.run }
  end

  # The test environment logs at a higher threshold than production's INFO, so
  # the capture runs at DEBUG to see a leak at any level. API controllers do not
  # write through ActionController::Base.logger, so all three loggers are
  # swapped. The capture is tagged, or the request tags would not reach it.
  def capture_entry_logs
    io = StringIO.new
    logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(io))
    logger.level = Logger::DEBUG
    previous = [Rails.logger, ActionController::Base.logger, ActionController::API.logger]
    Rails.logger = logger
    ActionController::Base.logger = logger
    ActionController::API.logger = logger
    yield
    io.string
  ensure
    Rails.logger, ActionController::Base.logger, ActionController::API.logger = previous
  end

  def get_entries(query: {}, authorization: "Bearer #{token}", request_id: SecureRandom.uuid, company_id: company_a)
    get "/v1/companies/#{company_id}/entries", params: query,
      headers: { "Authorization" => authorization, "X-Request-Id" => request_id }
  end

  it "catches markers written through Rails.logger and the controller's own logger" do
    rails_marker = "rails-marker-#{SecureRandom.hex(8)}"
    controller_marker = "controller-marker-#{SecureRandom.hex(8)}"

    log = capture_entry_logs do
      Rails.logger.info(rails_marker)
      Timekeeping::V1::EntriesController.logger.info(controller_marker)
    end

    expect(log).to include(rails_marker, controller_marker)
  end

  it "never logs a token sent in note, proof_url, project_id or the Authorization header" do
    planted = mint_token({ sub: 8, company_id: company_a, role: "admin" })

    log = capture_entry_logs do
      get_entries(query: { note: planted, proof_url: "https://x.test/?t=#{planted}", source_metadata: { token: planted } })
      get_entries(query: { project_id: planted })
    end

    expect(log).to include("Started GET")
    expect(log).not_to include(planted)
    expect(log).not_to include(token)
  end

  it "never logs the service token sent as a parameter or as the request id" do
    log = capture_entry_logs do
      get_entries(query: { project_id: service_token })
      get_entries(request_id: service_token)
    end

    expect(log).to include("Started GET")
    expect(log).not_to include(service_token)
  end

  it "never logs a token sent in place of the company or entry id in the path" do
    planted_jwt = mint_token({ sub: 8, company_id: company_a, role: "admin" })
    headers = { "Authorization" => "Bearer #{token}" }

    log = capture_entry_logs do
      get "/v1/companies/#{service_token}/entries", headers: headers
      get "/v1/companies/#{company_a}/entries/#{service_token}", headers: headers
      # A JWT holds dots, so this path matches no route and takes the routing error path.
      get "/v1/companies/#{company_a}/entries/#{planted_jwt}", headers: headers
    end

    expect(log).to include(
      %(Started GET "/v1/companies/[FILTERED]/entries"),
      %(Started GET "/v1/companies/#{company_a}/entries/[FILTERED]")
    )
    expect(log).not_to include(service_token)
    expect(log).not_to include(planted_jwt)
    expect(log).not_to include(planted_jwt.split(".").first)
  end

  it "never logs a token sent as a parameter name, at the top level or under an allowed name" do
    log = capture_entry_logs do
      get "/v1/companies/#{company_a}/entries?#{service_token}=value&project_id[#{service_token}]=5",
        headers: { "Authorization" => "Bearer #{token}" }
    end

    expect(log).to include("Started GET", "Parameters:")
    expect(log).not_to include(service_token)
  end

  it "never logs a token sent as the HTTP method" do
    log = capture_entry_logs do
      process(service_token.to_sym, "/v1/companies/#{company_a}/entries", headers: { "Authorization" => "Bearer #{token}" })
    end

    expect(log).to include(%(Started [FILTERED] "/v1/companies/#{company_a}/entries"))
    expect(log.downcase).not_to include(service_token)
  end

  it "digests a UUID request id that equals a UUID service token" do
    uuid_service_token = SecureRandom.uuid

    log = with_timekeeping_env(Timekeeping::Environment::SERVICE_TOKEN => uuid_service_token) do
      capture_entry_logs { get_entries(request_id: uuid_service_token) }
    end

    expect(log).to include("Started GET", "request_id=sha256:")
    expect(log).not_to include(uuid_service_token)
  end

  it "never logs a numeric service token sent as project_id or as a path id" do
    numeric_service_token = Array.new(19) { SecureRandom.random_number(1..9) }.join
    headers = { "Authorization" => "Bearer #{token}" }

    log = with_timekeeping_env(Timekeeping::Environment::SERVICE_TOKEN => numeric_service_token) do
      capture_entry_logs do
        get "/v1/companies/#{company_a}/entries", params: { project_id: numeric_service_token }, headers: headers
        get "/v1/companies/#{numeric_service_token}/entries", headers: headers
        get "/v1/companies/#{company_a}/entries/#{numeric_service_token}", headers: headers
      end
    end

    expect(log).to include("Started GET", "Parameters:")
    expect(log).not_to include(numeric_service_token)
  end

  it "logs an allowed id and a UUID request id in clear, and masks other values" do
    request_id = SecureRandom.uuid

    log = capture_entry_logs { get_entries(query: { project_id: "5", note: "private words" }, request_id:) }

    expect(log).to include("project_id=5", "request_id=#{request_id}")
    expect(log).not_to include("private words")
  end

  it "tags every line of a verified request with the token's company, the request id and the user actor" do
    request_id = SecureRandom.uuid

    log = capture_entry_logs { get_entries(request_id:) }
    lines = log.lines.reject { |line| line.strip.empty? }

    expect(lines).to include(a_string_including("Started GET"), a_string_including("Completed 200"))
    expect(lines).to all(include("[company_id=#{company_a}] [request_id=#{request_id}] [actor=user]"))
  end

  it "logs company_id=unverified for a forged token on a company path, never the path's company" do
    forged = mint_token({ sub: 7, company_id: 42, role: "owner" }, key: OpenSSL::PKey::RSA.generate(2048))

    log = capture_entry_logs { get_entries(authorization: "Bearer #{forged}", company_id: 42) }

    expect(log).to include("Completed 401", "company_id=unverified", "actor=anonymous")
    expect(log).not_to include("company_id=42")
  end
end
