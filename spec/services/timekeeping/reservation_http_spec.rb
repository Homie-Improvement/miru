# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::ReservationHttp do
  it "a transport failure raises ReservationHttp::Error naming the exception class but never the token or the body" do
    token = "secret-service-token-#{SecureRandom.hex(8)}"
    operation_id = "secret-operation-#{SecureRandom.hex(8)}"
    # Stubbed so no socket is opened; this is the transport's own spec.
    allow(Net::HTTP).to receive(:start).and_raise(SocketError, "getaddrinfo failed for #{token}")
    http = described_class.new(base_url: "http://timekeeping.test")

    # "The error message names only the route and the exception class, never the token or the body."
    expect do
      http.call("POST", "/v1/companies/5/reservations/prepare",
                headers: { "Authorization" => "Bearer #{token}" },
                body: { "invoice_id" => 9, "operation_id" => operation_id, "generation" => 2,
                        "disposition" => "active", "entries" => [77] })
    end.to raise_error(Timekeeping::ReservationHttp::Error) { |error|
      expect(error.message).to include("SocketError")
      expect(error.message).not_to include(token)
      expect(error.message).not_to include(operation_id)
    }
  end
end

RSpec.describe Timekeeping::ReservationHttp do
  # "It raises `ReservationHttp::Error` when the base URL is blank."
  it "a blank base URL raises the reservation transport error without opening a connection" do
    expect(Net::HTTP).not_to receive(:start)

    expect do
      described_class.new(base_url: "").call(
        "POST", "/v1/companies/7/reservations/prepare",
        headers: { "Authorization" => "Bearer secret-token" }, body: { "invoice_id" => 501 }
      )
    end.to raise_error(described_class::Error) { |error| expect(error.message).not_to include("secret-token") }
  end
end

RSpec.describe Timekeeping::ReservationHttp, "timeouts" do
  # "It also raises that error for SystemCallError, IOError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError, Net::ProtocolError and JSON::ParserError."
  # "The error message names only the route and the exception class, never the token or the body."
  # "a timeout or 5xx maps to retryable"
  it "a read timeout is wrapped in the reservation transport error naming only the route and class, and the client answers it as retryable" do
    allow(Net::HTTP).to receive(:start).and_raise(Net::ReadTimeout)
    secret_token = "tk-timeout-secret-#{SecureRandom.hex(8)}"
    path = "/v1/companies/7/reservations/prepare"
    body = { "invoice_id" => 10, "operation_id" => "op-timeout-body-marker", "generation" => 1,
             "disposition" => "active", "entries" => [3] }
    transport = described_class.new(base_url: "http://timekeeping.test")

    expect do
      transport.call("POST", path, headers: { "Authorization" => "Bearer #{secret_token}" }, body:)
    end.to raise_error(Timekeeping::ReservationHttp::Error) { |error|
      expect(error.message).to include("Net::ReadTimeout")
      expect(error.message).not_to include(secret_token)
      expect(error.message).not_to include("op-timeout-body-marker")
    }

    client = Timekeeping::ReservationClient.new(http: transport, credential: ->(company_id:, operation:) { secret_token })
    request = Invoices::ReservationRequest.new(company_id: 7, invoice_id: 10, operation_id: "op-timeout-body-marker",
                                               generation: 1, disposition: "active", entries: [3])
    outcome = client.prepare(request)

    expect(outcome).to be_a(Invoices::ReservationOutcome)
    expect(outcome.state).to eq("retryable")
    expect(outcome.conflicts).to eq([])
  end
end

RSpec.describe Timekeeping::ReservationHttp, "answers and wrapped failures" do
  let(:reservation_http_base_url) { "http://timekeeping.test" }
  let(:reservation_http_path) { "/v1/companies/7/reservations/prepare" }

  it "wraps every listed transport exception in ReservationHttp::Error naming the route and the class only" do
    token = "reservation-http-token-#{SecureRandom.hex(8)}"
    [Errno::ECONNREFUSED, IOError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError, Net::ProtocolError,
     JSON::ParserError].each do |exception_class|
      allow(Net::HTTP).to receive(:start).and_raise(exception_class)

      expect do
        described_class.new(base_url: reservation_http_base_url).call(
          "POST", reservation_http_path, headers: { "Authorization" => "Bearer #{token}" },
                                         body: { "operation_id" => "reservation-http-body-marker" }
        )
      end.to raise_error(described_class::Error) { |error|
        expect(error.message).to include("POST #{reservation_http_path}", exception_class.name)
        expect(error.message).not_to include(token)
        expect(error.message).not_to include("reservation-http-body-marker")
      }
    end
  end

  it "raises ReservationHttp::Error when the answer body is not JSON" do
    stub_request(:post, "#{reservation_http_base_url}#{reservation_http_path}").to_return(status: 200, body: "<html>")

    expect do
      described_class.new(base_url: reservation_http_base_url).call("POST", reservation_http_path, headers: {}, body: {})
    end.to raise_error(described_class::Error, /JSON::ParserError/)
  end

  it "returns a 409 answer with its status and string-keyed parsed body instead of raising" do
    stub_request(:post, "#{reservation_http_base_url}#{reservation_http_path}")
      .with(body: { "invoice_id" => 9 }.to_json, headers: { "Authorization" => "Bearer reservation-http-409" })
      .to_return(status: 409, body: { reason: "stale_generation" }.to_json)

    response = described_class.new(base_url: reservation_http_base_url).call(
      "POST", reservation_http_path, headers: { "Authorization" => "Bearer reservation-http-409" },
                                     body: { "invoice_id" => 9 }
    )

    expect(response.status).to eq(409)
    expect(response.body).to eq("reason" => "stale_generation")
  end

  it "starts an https connection with TLS and the entry API timeouts" do
    stub_request(:post, "https://timekeeping.test#{reservation_http_path}").to_return(status: 200, body: "{}")
    allow(Net::HTTP).to receive(:start).and_call_original

    described_class.new(base_url: "https://timekeeping.test").call("POST", reservation_http_path, headers: {}, body: {})

    expect(Net::HTTP).to have_received(:start).with(
      "timekeeping.test", 443,
      use_ssl: true,
      open_timeout: Timekeeping::EntryApiClient::TIMEOUT_SECONDS,
      read_timeout: Timekeeping::EntryApiClient::TIMEOUT_SECONDS
    )
  end
end

RSpec.describe Timekeeping::ServiceToken, "reservation operations" do
  it "names reservation operations Timekeeping's background allowlist grants" do
    operations = [described_class::RESERVATIONS_PREPARE, described_class::RESERVATIONS_COMMIT,
                  described_class::RESERVATIONS_ABORT, described_class::INVOICES_MARK_BILLED]

    expect(operations).to eq(%w[reservations.prepare reservations.commit reservations.abort invoices.mark_billed])
    expect(operations - TimekeepingRules::EntryRules::BACKGROUND_OPERATIONS).to be_empty
  end
end
