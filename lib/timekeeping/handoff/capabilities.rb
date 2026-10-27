# frozen_string_literal: true

module Timekeeping
  module Handoff
    # Decides, before any side effect, whether a handoff can start. Closing
    # the ownership row does not stop an entry writer that never reads it, so
    # an edit saved after the checkpoint would be lost unless each owner has
    # an admission adapter that really fences its writers. Settling and
    # draining likewise need integrations this repository does not hold for a
    # non-legacy source. Pure: it only inspects the configured objects.
    class Capabilities
      ADMISSION_METHODS = %i[fence_admission admit enforces_fence?].freeze
      # The calls the runner makes on a non-legacy source's integrations, so
      # one that lacks any is refused before admission closes.
      SETTLE_METHODS = %i[settle! settled? stop_applying!].freeze
      DRAIN_METHODS = %i[drain! drained?].freeze

      # Returns why the handoff cannot start, or nil when it can.
      def refusal(source_legacy:, outgoing:, incoming:)
        [outgoing, incoming].each do |owner|
          return "#{owner.name} has no admission adapter that enforces its fence" unless enforcing?(owner.admission)
        end
        # The legacy monolith registers no invoice operations and has no entry
        # outbox, so the runner only checks that none remain unresolved.
        return if source_legacy
        return "#{outgoing.name} has no working settle integration configured" unless responds?(outgoing.settle, SETTLE_METHODS)
        return "#{outgoing.name} has no working drain integration configured" unless responds?(outgoing.drain, DRAIN_METHODS)

        nil
      end

      private

        def enforcing?(admission)
          responds?(admission, ADMISSION_METHODS) && admission.enforces_fence? == true
        end

        def responds?(integration, methods)
          methods.all? { |method| integration.respond_to?(method) }
        end
    end
  end
end
