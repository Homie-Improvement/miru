# frozen_string_literal: true

module Timekeeping
  # The endpoint the snapshot relay posts through. It passes every answer back
  # unchanged and writes one log line for each answer the relay will not count
  # as delivered (TimekeepingRelay::Response#delivered?), a malformed 200
  # included, since that answer also stops the run. That
  # line holds only the status and a fixed reason from
  # TimekeepingRelay::FailureReason, because a response body is text the
  # consumer chose and could echo the bearer token.
  class SnapshotEndpoint
    # The endpoint the service uses: the host and credential come only from the
    # process environment, never from outbox data or a response.
    def self.configured(logger: Rails.logger)
      endpoint = TimekeepingRelay::HttpEndpoint.new(url: Environment.monolith_snapshot_url,
                                                    token: Environment.service_token)
      new(endpoint:, logger:)
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

    private

      attr_reader :endpoint, :logger

      def log_failure(answer)
        # to_i, so a status that is not a number is never copied into the line.
        status = answer.status.nil? ? "none" : answer.status.to_i
        logger.warn("entry snapshot delivery failed status=#{status} reason=#{TimekeepingRelay::FailureReason.for(answer)}")
      end
  end
end
