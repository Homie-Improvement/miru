# frozen_string_literal: true

require "net/http"

module Timekeeping
  # Reads the Timekeeping service's GET /internal/v1/metrics body: per-company
  # write counts, latency buckets and outbox lag, for the alert task. The body
  # holds every company's counts, so the service only answers the service
  # identity, and this client never calls without it.
  #
  # It never retries. Every failure raises this class's Error, whose message
  # names the failure but never the token, so a caller can print it safely.
  class MetricsClient
    METRICS_PATH = "/internal/v1/metrics"
    TIMEOUT_SECONDS = 5
    # The top-level fields Timekeeping::Alerts reads. A body without one, such
    # as one from an older Timekeeping, is a failed read rather than a crash
    # later in evaluation.
    REQUIRED_FIELDS = %w[window_seconds latency_bucket_bounds_ms overflow_bucket companies outbox_lag].freeze

    class Error < StandardError; end

    def initialize(base_url: ENV[EntryApiClient::BASE_URL_ENV],
                   service_token: ENV[Internal::V1::BaseController::SERVICE_TOKEN_ENV])
      @base_url = base_url.to_s
      @service_token = service_token.to_s
    end

    def fetch
      raise Error, "#{EntryApiClient::BASE_URL_ENV} is not set" if @base_url.blank?
      raise Error, "#{Internal::V1::BaseController::SERVICE_TOKEN_ENV} is not set" if @service_token.empty?

      response = get(URI.join(@base_url, METRICS_PATH))
      raise Error, "Timekeeping metrics answered #{response.code}" unless response.is_a?(Net::HTTPOK)

      body = JSON.parse(response.body)
      complete = body.is_a?(Hash) && REQUIRED_FIELDS.all? { |field| body.key?(field) }
      raise Error, "Timekeeping metrics body is missing fields" unless complete

      body
    rescue URI::InvalidURIError, SystemCallError, IOError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError,
           Net::HTTPBadResponse, Net::ProtocolError, JSON::ParserError => error
      raise Error, "Timekeeping metrics read failed: #{error.class}"
    end

    private

      def get(uri)
        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = "Bearer #{@service_token}"
        request["Accept"] = "application/json"
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                            open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS) do |http|
          http.request(request)
        end
      end
  end
end
