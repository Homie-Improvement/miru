# frozen_string_literal: true

module Timekeeping
  module Handoff
    # The handoff procedure of docs/architecture/timekeeping-soa.md section
    # 10.5 as data, and the pure decision of what a runner call should do
    # given the ownership row. Nothing here reads the database or calls a
    # store: the runner carries out what this decides.
    #
    # Each row names the step as handoff_step records it, the runner method
    # that does the step's work, and the runner method that confirms the work
    # finished. The runner records a step only after its completion check
    # passes, so a step whose work did not finish stays unrecorded and runs
    # again on resume.
    module Steps
      TABLE = [
        { name: "close_admission", action: :close_admission, completion_check: :admission_closed? },
        { name: "settle", action: :settle, completion_check: :settled? },
        { name: "freeze", action: :freeze, completion_check: :drained? },
        { name: "checkpoint", action: :checkpoint, completion_check: :checkpoint_loaded? },
        { name: "sequence", action: :advance_sequence, completion_check: :sequence_advanced? },
        { name: "reconcile", action: :reconcile, completion_check: :reconciled? },
        { name: "flip", action: :flip, completion_check: :flipped? }
      ].map(&:freeze).freeze

      NAMES = TABLE.pluck(:name).freeze

      # The steps an abort must finish before the outgoing owner admits writes
      # again: settle and freeze, so no operation is left prepared and every
      # outbox snapshot up to P reaches the projection.
      ABORT_COMPLETES = %w[settle freeze].freeze

      # Each direction names the owner it moves from and to, and whether its
      # source is the legacy monolith. The legacy marker, not the generation,
      # tells a first cutover from a re-cutover: an aborted first cutover keeps
      # its raised generation.
      DIRECTIONS = {
        cutover: { from: "monolith", to: "timekeeping", source_legacy: true },
        re_cutover: { from: "monolith", to: "timekeeping", source_legacy: false },
        rollback: { from: "timekeeping", to: "monolith", source_legacy: false }
      }.transform_values(&:freeze).freeze

      # kind is :start, :resume, :abort, :readmit or :refuse. step is the
      # step to run next (:resume); owed lists the steps an abort must finish
      # first (:abort); owner is the owner to admit again (:readmit); reason
      # explains a :refuse.
      Decision = Data.define(:kind, :step, :owed, :owner, :reason) do
        def self.start = new(kind: :start, step: NAMES.first, owed: [].freeze, owner: nil, reason: nil)
        def self.resume(step) = new(kind: :resume, step:, owed: [].freeze, owner: nil, reason: nil)
        def self.abort(owed) = new(kind: :abort, step: nil, owed: owed.freeze, owner: nil, reason: nil)
        def self.readmit(owner) = new(kind: :readmit, step: nil, owed: [].freeze, owner:, reason: nil)
        def self.refuse(reason) = new(kind: :refuse, step: nil, owed: [].freeze, owner: nil, reason:)
      end

      module_function

      # state responds to owner, handoff_step and legacy_retired_at, as the
      # ownership row does.
      def decide(state, direction:, abort:, resume:)
        route = DIRECTIONS[direction]
        return Decision.refuse("Unknown handoff direction #{direction.inspect}") unless route

        if state.handoff_step.nil?
          decide_idle(state, direction, route, abort:, resume:)
        else
          decide_in_progress(state, direction, route, abort:, resume:)
        end
      end

      # The steps after the given recorded step, in order.
      def remaining(after:)
        NAMES.drop(NAMES.index(after.to_s) + 1)
      end

      def decide_in_progress(state, direction, route, abort:, resume:)
        unless starts_from_current_owner?(state, route)
          return Decision.refuse("A handoff from #{state.owner} is in progress at step #{state.handoff_step}; " \
                                 "#{direction} does not match it")
        end
        return Decision.abort(ABORT_COMPLETES & remaining(after: state.handoff_step)) if abort
        return Decision.refuse("A handoff is in progress at step #{state.handoff_step}; resume or abort it") unless resume

        Decision.resume(remaining(after: state.handoff_step).first)
      end

      # With no step recorded, an abort can only follow a close admission that
      # fenced the owners and then timed out before recording its step, so it
      # admits the current owner again and starts nothing. A resume naming the
      # direction that last flipped re-sends the admit call the flip may have
      # failed to deliver; the legacy marker is set by every flip, so a row
      # that never flipped has nothing to re-admit.
      def decide_idle(state, direction, route, abort:, resume:)
        if abort
          return Decision.readmit(state.owner) if starts_from_current_owner?(state, route)

          return Decision.refuse("No handoff is in progress, and #{direction} does not start from #{state.owner}")
        end
        return Decision.start if starts_from_current_owner?(state, route)
        return Decision.readmit(state.owner) if resume && just_flipped_to_current_owner?(state, route)

        Decision.refuse("#{direction} does not start from the current owner #{state.owner}" \
                        "#{legacy_note(state)}")
      end

      def starts_from_current_owner?(state, route)
        route[:from] == state.owner && route[:source_legacy] == state.legacy_retired_at.nil?
      end

      def just_flipped_to_current_owner?(state, route)
        route[:to] == state.owner && !state.legacy_retired_at.nil?
      end

      def legacy_note(state)
        state.legacy_retired_at.nil? ? " with a legacy source" : " with legacy retired"
      end

      private_class_method :decide_in_progress, :decide_idle, :starts_from_current_owner?,
                           :just_flipped_to_current_owner?, :legacy_note
    end
  end
end
