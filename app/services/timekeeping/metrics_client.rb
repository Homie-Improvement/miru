# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"

module Timekeeping
  # Reads the Timekeeping service's per-company write metrics from
  # GET /internal/v1/metrics with the service token. Any failure to read a
  # well-formed body raises Unavailable, so the alert task reports an error
  # instead of reading a broken or refused answer as "no alerts".
  class MetricsClient
    class Unavailable < StandardError; end

    BASE_URL_ENV = "TIMEKEEPING_BASE_URL"
    METRICS_PATH = "/internal/v1/metrics"
    TIMEOUT_SECONDS = 2
    TRANSPORT_ERRORS = [Timeout::Error, SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError,
                        Net::HTTPBadResponse, Net::ProtocolError].freeze
    WINDOW_COUNT_FIELDS = %w[writes reference_unavailable stale_generation latency_ms_sum].freeze

    # The host and the credential come only from the process environment, with
    # no default, so an unconfigured host never sends an unauthenticated read.
    def self.configured
      new(base_url: ENV[BASE_URL_ENV], service_token: ENV[Internal::V1::BaseController::SERVICE_TOKEN_ENV])
    end

    def initialize(base_url:, service_token:, open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS)
      @base_url = base_url
      @service_token = service_token
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    # Returns the parsed body unchanged once every field the alert evaluator
    # reads has the expected shape.
    def fetch
      response = get(metrics_uri)
      raise Unavailable, "metrics endpoint answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      parse(response.body)
    end

    private

      attr_reader :base_url, :service_token, :open_timeout, :read_timeout

      def metrics_uri
        raise Unavailable, "#{BASE_URL_ENV} is not set" if base_url.to_s.strip.empty?

        uri = URI.parse("#{base_url.chomp("/")}#{METRICS_PATH}")
        raise Unavailable, "#{BASE_URL_ENV} is not an http(s) URL" unless uri.is_a?(URI::HTTP) && uri.host

        uri
      rescue URI::InvalidURIError
        raise Unavailable, "#{BASE_URL_ENV} is not a valid URL"
      end

      # Error messages name the status or exception class only, never the
      # request, so the token cannot reach a log line.
      def get(uri)
        token_env = Internal::V1::BaseController::SERVICE_TOKEN_ENV
        raise Unavailable, "#{token_env} is not set" if service_token.to_s.empty?

        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = "Bearer #{service_token}"
        request["Accept"] = "application/json"
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                            open_timeout:, read_timeout:) { |http| http.request(request) }
      rescue *TRANSPORT_ERRORS => e
        raise Unavailable, "metrics endpoint unreachable (#{e.class})"
      end

      def parse(body)
        metrics = JSON.parse(body.to_s)
        raise Unavailable, "metrics response is malformed" unless valid_metrics?(metrics)

        metrics
      rescue JSON::ParserError
        raise Unavailable, "metrics response is not JSON"
      end

      def valid_metrics?(metrics)
        metrics.is_a?(Hash) &&
          ascending_bounds?(metrics["latency_bucket_bounds_ms"]) &&
          metrics["overflow_bucket"].is_a?(String) &&
          metrics["total_field"].is_a?(String) &&
          list_of?(metrics["companies"]) { |company| valid_company?(company) }
      end

      def ascending_bounds?(bounds)
        list_of?(bounds) { |bound| bound.is_a?(Integer) && bound.positive? } &&
          bounds.any? && bounds.each_cons(2).all? { |lower, upper| lower < upper }
      end

      def valid_company?(company)
        company.is_a?(Hash) &&
          company["company_id"].is_a?(Integer) &&
          list_of?(company["windows"]) { |window| valid_window?(window) }
      end

      def valid_window?(window)
        window.is_a?(Hash) &&
          iso8601?(window["window_start"]) &&
          WINDOW_COUNT_FIELDS.all? { |field| window[field].is_a?(Integer) } &&
          window["latency_ms_buckets"].is_a?(Hash) &&
          window["latency_ms_buckets"].all? { |key, count| key.is_a?(String) && count.is_a?(Integer) }
      end

      def iso8601?(value)
        value.is_a?(String) && Time.iso8601(value)
      rescue ArgumentError
        false
      end

      def list_of?(value, &valid)
        value.is_a?(Array) && value.all?(&valid)
      end
  end
end
