# frozen_string_literal: true

module TimekeepingRelay
  # Turns a failed answer into a fixed reason that is safe to log. A response
  # body is text the consumer chose, and it could echo the bearer token, so
  # nothing from it is passed on unless it is one of the contract's own error
  # answers (contracts/timekeeping/entry_snapshots.yml errors).
  module FailureReason
    KNOWN_REASONS = {
      409 => "stale_generation",
      404 => "not_found",
      401 => "unauthorized",
      403 => "forbidden"
    }.freeze
    UNAVAILABLE = "unavailable"
    UNRECOGNIZED = "unrecognized"

    module_function

    def for(response)
      return UNAVAILABLE if response.status.nil?

      reason = response.body["reason"] if response.body.is_a?(Hash)
      known = KNOWN_REASONS[response.status]
      known && reason == known ? known : UNRECOGNIZED
    end
  end
end
