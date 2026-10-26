# frozen_string_literal: true

module Timekeeping
  # The one monolith module allowed to write entry state
  # (docs/architecture/timekeeping-soa.md sections 3.1 and 10.1).
  class Gateway
    # Raised when an entry write is refused because ownership is moving, or
    # cannot be read. Retryable: the write succeeds once the handoff ends. A
    # subclass of the billing refusal, so every place that already renders or
    # re-raises that refusal as 503 ownership_moving handles this one too.
    class OwnershipMoving < BillingFence::OwnershipMoving; end

    # Raised when the caller expected a different ownership generation than
    # the one the write saw. Rendered as 409 stale_generation.
    class StaleGeneration < StandardError
      def initialize(message = "stale_generation")
        super
      end
    end

    # The local-owner dependency until the prepared monolith's entry writer
    # exists. The prepared store must never be written by anything else, so
    # every call refuses as a retryable ownership move rather than writing.
    class UnavailableLocalOwner
      def find_entry(**)
        raise OwnershipMoving
      end

      def create_entry(**)
        raise OwnershipMoving
      end

      def update_entry(**)
        raise OwnershipMoving
      end

      def destroy_entry(**)
        raise OwnershipMoving
      end
    end
  end
end
