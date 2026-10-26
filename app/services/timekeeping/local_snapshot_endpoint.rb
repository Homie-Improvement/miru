# frozen_string_literal: true

module Timekeeping
  # The endpoint the monolith's own snapshot relay posts the local entry outbox
  # through, to this application's projection endpoint. It passes every answer
  # back unchanged and writes one log line for each answer the relay will not
  # count as delivered (TimekeepingRelay::Response#delivered?). That line holds
  # only the status and a fixed reason from TimekeepingRelay::FailureReason,
  # because a response body is text the consumer chose and could echo the
  # bearer token.
  class LocalSnapshotEndpoint
    # The monolith's own base URL. TIMEKEEPING_BASE_URL names the Timekeeping
    # service, which is not the consumer of this outbox, so it is never read here.
    PROJECTION_URL_ENV = "TIMEKEEPING_PROJECTION_URL"
    LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1].freeze

    # The host and credential come only from the process environment, never
    # from outbox data or a response.
    def self.configured(logger: Rails.logger)
      endpoint = TimekeepingRelay::HttpEndpoint.new(
        url: protected_url(ENV.fetch(PROJECTION_URL_ENV, nil)),
        token: ENV.fetch(Internal::V1::BaseController::SERVICE_TOKEN_ENV, nil)
      )
      new(endpoint:, logger:)
    end

    # The URL when the token and snapshots it would carry stay protected:
    # https, or plain http to a loopback host that never leaves the machine.
    # Plain http to any other host would send the service token, which the
    # internal API accepts for every company, and customers' entries in clear
    # text, so it gives nil and HttpEndpoint then makes no request.
    def self.protected_url(url)
      uri = URI.parse(url.to_s)
      return url if uri.is_a?(URI::HTTPS) && uri.host.present?
      return url if uri.instance_of?(URI::HTTP) && LOOPBACK_HOSTS.include?(uri.hostname)

      nil
    rescue URI::InvalidURIError
      nil
    end

    def initialize(endpoint:, logger:)
      @endpoint = endpoint
      @logger = logger
    end

    def deliver(batch, idempotency_key:)
      answer = endpoint.deliver(batch, idempotency_key:)
      log_failure(answer) unless answer.delivered?(batch.fetch("snapshots").size)
      answer
    end

    # Keeps the wrapped endpoint, and the token it holds, out of anything that
    # prints this one.
    def inspect
      "#<#{self.class.name}>"
    end
    alias to_s inspect

    private

      attr_reader :endpoint, :logger

      def log_failure(answer)
        # to_i, so a status that is not a number is never copied into the line.
        status = answer.status.nil? ? "none" : answer.status.to_i
        logger.warn("entry snapshot delivery failed status=#{status} reason=#{TimekeepingRelay::FailureReason.for(answer)}")
      end
  end
end
