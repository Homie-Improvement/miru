# frozen_string_literal: true

require "net/http"

module Timekeeping
  # Sends one reservation request to the Timekeeping service
  # (contracts/timekeeping/reservations.yml) and returns its status and parsed
  # body, whatever the status; deciding what an answer means is the caller's
  # job. Every Net:: exception ends here, so callers see only
  # ReservationHttp::Error.
  #
  # Error messages name only the route and the exception class, never the
  # token or a body, because they end up in logs and outbox error reports.
  class ReservationHttp
    class Error < StandardError; end

    Response = Data.define(:status, :body)

    TRANSPORT_ERRORS = [
      SystemCallError, IOError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError, Net::ProtocolError,
      JSON::ParserError
    ].freeze

    def initialize(base_url: ENV[EntryApiClient::BASE_URL_ENV])
      @base_url = base_url.to_s
    end

    def call(method, path, headers: {}, body: nil)
      route = "#{method.to_s.upcase} #{path}"
      raise Error, "#{EntryApiClient::BASE_URL_ENV} is not set" if @base_url.blank?

      response = send_request(build_request(method, path, headers, body))
      Response.new(status: response.code.to_i, body: parse(response.body))
    rescue *TRANSPORT_ERRORS => error
      raise Error, "Timekeeping #{route} failed: #{error.class}"
    end

    private

      def build_request(method, path, headers, body)
        request = Net::HTTPGenericRequest.new(method.to_s.upcase, !body.nil?, true, URI.join(@base_url, path))
        headers.to_h.each { |name, value| request[name.to_s] = value.to_s }
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body) unless body.nil?
        request
      end

      # An empty body is passed on as nil for the caller to judge; any other
      # body that is not JSON raises JSON::ParserError, wrapped above.
      def parse(raw)
        raw.to_s.empty? ? nil : JSON.parse(raw)
      end

      def send_request(request)
        uri = request.uri
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                            open_timeout: EntryApiClient::TIMEOUT_SECONDS,
                                            read_timeout: EntryApiClient::TIMEOUT_SECONDS) do |http|
          http.request(request)
        end
      end
  end
end
