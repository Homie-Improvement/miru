# frozen_string_literal: true

module Timekeeping
  # Who is writing entries, for which company, under which request. The
  # gateway reads identity only from here, never from Current, so a write
  # started outside a web request (a job, the CLI, an agent) names its actor
  # explicitly and cannot pick up whoever Current happens to hold.
  #
  # actor is the user the write acts for, and the user a forwarded write's
  # token is minted for. agent is set only when an agent acts for that user.
  class WriteContext < Data.define(:company, :actor, :actor_kind, :request_id, :agent)
    ACTOR_KINDS = %w[user agent service].freeze

    def initialize(company:, actor:, actor_kind:, request_id:, agent: nil)
      actor_kind = actor_kind.to_s
      raise ArgumentError, "unknown actor_kind #{actor_kind.inspect}" unless ACTOR_KINDS.include?(actor_kind)

      super
    end
  end
end
