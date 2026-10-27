# frozen_string_literal: true

module Timekeeping
  module Handoff
    # The runner's default observer. The runner reports :before_step,
    # :after_step, :during_checkpoint and :after_corrections to its observer;
    # only specs supply one that acts on them.
    class NullObserver
      def call(_event, step:)
        nil
      end
    end
  end
end
