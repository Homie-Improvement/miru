# frozen_string_literal: true

module Timekeeping
  module Handoff
    # What every owner's store does during a handoff, per
    # docs/architecture/timekeeping-soa.md sections 10.3 and 10.5. Rows move
    # in the shape Checkpoint::TABLES defines, so a checkpoint one store
    # exports loads into any other.
    module Store
      # A store refused to export or load, naming the table and company that
      # stopped it.
      class Error < StandardError; end

      # Reads every checkpoint table in one REPEATABLE READ, read only snapshot.
      def export_checkpoint
        raise NotImplementedError, "#{self.class} must export a checkpoint"
      end

      # Replaces the store's checkpoint tables with the checkpoint's rows in
      # one transaction, and rolls back when the rows read back do not match
      # the checkpoint's digest.
      def load_checkpoint(_checkpoint)
        raise NotImplementedError, "#{self.class} must load a checkpoint"
      end

      def highest_outbox_position
        raise NotImplementedError, "#{self.class} must report its highest outbox position"
      end

      # Moves the entry id sequence so the next id is above `above`, and never
      # moves it backwards.
      def advance_entry_id_sequence(above:)
        raise NotImplementedError, "#{self.class} must advance its entry id sequence"
      end
    end
  end
end
