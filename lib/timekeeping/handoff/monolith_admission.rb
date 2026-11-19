# frozen_string_literal: true

module Timekeeping
  module Handoff
    # The monolith's admission adapter (docs/architecture/timekeeping-soa.md
    # section 10.5 step 1). Every monolith entry and billing writer holds the
    # timekeeping_ownership row FOR SHARE and refuses while
    # TimekeepingOwnership#admission_closed? is true. Fencing marks that row
    # with admission_fenced_at through an UPDATE, whose row lock waits for the
    # writers already admitted, so none can commit after the fence returns.
    # Runner#close_admission clears the mark in the same update that records
    # its step, and admit clears it when the handoff is abandoned.
    class MonolithAdmission
      # How long a fence waits for writes already admitted before it gives up.
      FENCE_LOCK_TIMEOUT = 60.seconds

      def initialize(lock_timeout: FENCE_LOCK_TIMEOUT)
        @lock_timeout = lock_timeout
      end

      # Raises ActiveRecord::LockWaitTimeout when admitted writes outlast the
      # lock timeout; the transaction then rolls back and leaves no mark.
      # SET LOCAL ends with the transaction, so the short timeout never stays
      # on a pooled connection.
      def fence_admission
        TimekeepingOwnership.transaction do
          timeout_ms = Integer(@lock_timeout.in_milliseconds)
          TimekeepingOwnership.connection.execute("SET LOCAL lock_timeout = '#{timeout_ms}ms'")
          mark_fenced(Time.current)
        end
        nil
      end

      # Reopens the monolith. The ownership row already holds the generation
      # the writers check, so only the mark is cleared; on an unfenced row this
      # changes nothing, which a rollback relies on.
      def admit(generation:)
        raise ArgumentError, "generation must be a positive Integer" unless generation.is_a?(Integer) && generation.positive?

        mark_fenced(nil)
        nil
      end

      def enforces_fence?
        true
      end

      private

        # A missing row raises rather than counting as fenced or admitted;
        # writers already refuse when the row is missing.
        def mark_fenced(fenced_at)
          updated = TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID)
            .update_all(admission_fenced_at: fenced_at)
          return unless updated.zero?

          raise ActiveRecord::RecordNotFound.new("timekeeping_ownership row is missing", TimekeepingOwnership.name,
                                                 TimekeepingOwnership.primary_key, TimekeepingOwnership::SINGLETON_ID)
        end
    end
  end
end
