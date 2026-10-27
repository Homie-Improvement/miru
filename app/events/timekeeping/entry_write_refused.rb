# frozen_string_literal: true

module Timekeeping
  # One entry write the gateway refused, counted per company so operators can
  # see ownership_moving and stale_generation refusals during a handoff. The
  # record is the write's Timekeeping::WriteContext. The payload holds only
  # identifiers from it, never the token or the request body, because event
  # history is readable across every workspace.
  class EntryWriteRefused < ApplicationEvent
    REASONS = %w[ownership_moving stale_generation].freeze

    def initialize(context, reason:)
      @reason = reason.to_s
      raise ArgumentError, "unknown reason #{@reason.inspect}" unless REASONS.include?(@reason)

      super(context, actor: context.actor)
    end

    private

      def event_data
        {
          reason: @reason,
          company_id: record.company.id,
          request_id: record.request_id,
          actor_kind: record.actor_kind
        }
      end
  end
end
