# frozen_string_literal: true

module Timekeeping
  module Handoff
    # The drain integration of a non-legacy source (docs/architecture/
    # timekeeping-soa.md section 10.5 step 3): it drains the outgoing
    # owner's entry outbox into the projection through the final outbox
    # position P.
    #
    # drain! returning says nothing: a relay that could not take its lock, or
    # whose batch was refused, returns without sending. Only drained? answers
    # whether the projection holds P, and it asks the owner every time.
    class RelayDrain
      # The monolith as outgoing owner: its relay runs in this process, and
      # its outbox is entry_outbox_items.
      class MonolithPort
        # relay: runs one relay pass. RelayJob already sends batch after batch
        # until nothing is left or a batch is refused, so one pass is enough.
        def initialize(relay: -> { Timekeeping::RelayJob.perform_now })
          @relay = relay
        end

        def drain(through:)
          @relay.call
          nil
        end

        # Only rows at or below P must reach the projection before the flip,
        # so an unsent row above P does not count.
        def drained(through:)
          Timekeeping::LocalOutboxEntry.where(sent_at: nil, outbox_position: ..through).none?
        end
      end

      # Timekeeping as outgoing owner. Its drain route runs its relay and
      # answers whether every snapshot at or below through is sent, so both
      # calls make that request.
      class TimekeepingPort
        def initialize(store:)
          @store = store
        end

        def drain(through:)
          @store.drain(through:)
          nil
        end

        def drained(through:)
          @store.drain(through:)
        end
      end

      def initialize(owner:)
        @owner = owner
      end

      def drain!(through:)
        @owner.drain(through:)
        nil
      end

      def drained?(through:)
        @owner.drained(through:) == true
      end
    end
  end
end
