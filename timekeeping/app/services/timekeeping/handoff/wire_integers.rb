# frozen_string_literal: true

module Timekeeping
  module Handoff
    # Checks the integers a handoff request carries. A JSON string such as
    # "3", a decimal or a boolean is refused rather than converted: Integer()
    # would accept "3", and the handoff must act on the exact value sent.
    module WireIntegers
      # The largest value a bigint column holds. A generation is written to
      # the admission row, so a larger one would fail in the database.
      BIGINT_MAX = (2**63) - 1

      def self.generation?(value)
        value.is_a?(Integer) && value.between?(1, BIGINT_MAX)
      end

      # A position is only compared with stored positions, never written, so
      # it has no upper bound.
      def self.position?(value)
        value.is_a?(Integer) && !value.negative?
      end
    end
  end
end
