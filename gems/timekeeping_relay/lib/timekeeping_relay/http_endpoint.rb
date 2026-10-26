# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module TimekeepingRelay
  # Posts a batch to the projection endpoint of
  # contracts/timekeeping/entry_snapshots.yml. The caller passes the base URL
  # and the bearer token, so the gem reads no environment of its own.
  #
  # Every failure to get an answer becomes a Response with no status and no
  # body. An exception from Net::HTTP can repeat the URL or the request, and a
  # job's stored error or log line would then carry it; a Response with
  # nothing in it cannot.
  class HttpEndpoint
    DELIVER_PATH = "/internal/v1/timekeeping/entry-snapshots"
    TIMEOUT_SECONDS = 2
    TRANSPORT_ERRORS = [Timeout::Error, SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError,
                        Net::HTTPBadResponse, Net::ProtocolError].freeze
    NO_ANSWER = Response.new(status: nil, body: nil)

    attr_reader :open_timeout, :read_timeout

    def initialize(url:, token:, open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS)
      @url = url
      @token = token
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    def deliver(batch, idempotency_key:)
      uri = deliver_uri
      return NO_ANSWER if uri.nil? || token.to_s.empty?

      answer = post(uri, batch, idempotency_key)
      Response.new(status: answer.code.to_i, body: parse(answer.body))
    rescue *TRANSPORT_ERRORS
      NO_ANSWER
    end

    # Keeps the token out of anything that prints the endpoint.
    def inspect
      "#<#{self.class.name}>"
    end

    private

      attr_reader :url, :token

      def deliver_uri
        uri = URI.parse("#{url.to_s.chomp("/")}#{DELIVER_PATH}")
        uri if uri.is_a?(URI::HTTP) && uri.host
      rescue URI::InvalidURIError
        nil
      end

      def post(uri, batch, idempotency_key)
        request = Net::HTTP::Post.new(uri)
        request["Authorization"] = "Bearer #{token}"
        request["Idempotency-Key"] = idempotency_key
        request["Content-Type"] = "application/json"
        request["Accept"] = "application/json"
        request.body = JSON.generate(batch)
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                            open_timeout:, read_timeout:) { |http| http.request(request) }
      end

      # A body that is not JSON is dropped rather than kept as text, because
      # it is never read for anything but the contract's applied, ignored and
      # reason fields.
      def parse(body)
        JSON.parse(body.to_s)
      rescue JSON::ParserError
        nil
      end
  end
end
