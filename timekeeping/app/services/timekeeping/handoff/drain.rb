# frozen_string_literal: true

module Timekeeping
  module Handoff
    # Runs the snapshot relay once and reports whether every outbox snapshot
    # through a position has been sent (docs/architecture/timekeeping-soa.md
    # section 10.5). The answer is read from the table after the run, never
    # from what the relay returned, because a run can stop early on a refused
    # batch or a pause.
    #
    # A run that skipped because another run held the relay lock answers false
    # even when every row is already sent: the caller asks again, and a false
    # answer never lets a handoff go on with snapshots still unsent.
    #
    # Rows of the held generation are never offered by the relay
    # (RelayOutboxSource::HELD_GENERATION_EXCLUSION), yet they still count as
    # unsent here, so drain stays false until admit releases them.
    module Drain
      def self.call(through:)
        relay_ran = RelayJob.perform_now
        relay_ran && !unsent_through?(through)
      end

      # A position above the bigint range covers every stored row, so it is
      # capped there rather than sent to the database out of range.
      def self.unsent_through?(through)
        OutboxSnapshot.where(sent_at: nil)
                      .where(outbox_position: ..[through, WireIntegers::BIGINT_MAX].min)
                      .exists?
      end
      private_class_method :unsent_through?
    end
  end
end
