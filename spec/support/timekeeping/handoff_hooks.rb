# frozen_string_literal: true

# Observers that stop or watch a Timekeeping::Handoff::Runner run at a named
# point, so specs can interrupt a handoff and resume or abort it. They live
# only under spec/support, which only the test suite loads: no rake task,
# environment variable or runner default can select one, so a production run
# can never be halted by them.
module TimekeepingHandoffHooks
  # Raised by Interrupt, standing in for a crash at that point.
  class Interrupted < StandardError; end

  # Raises Interrupted at one point of a run. at is an event the runner
  # reports (:during_checkpoint, :after_corrections), or "after_" or
  # "before_" and a step name, such as :after_freeze.
  class Interrupt
    def initialize(at:)
      @at = at.to_s
    end

    def call(event, step:)
      point = event.to_s.delete_suffix("_step")
      return unless @at == event.to_s || @at == "#{point}_#{step}"

      raise Interrupted, "handoff interrupted at #{@at}"
    end
  end

  # Records every event with its step, in order.
  class Recorder
    attr_reader :events

    def initialize
      @events = []
    end

    def call(event, step:)
      @events << [event, step.to_s]
    end
  end
end
