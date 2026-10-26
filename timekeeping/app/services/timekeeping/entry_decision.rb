# frozen_string_literal: true

require "forwardable"

module Timekeeping
  # The request-value coercions of an entry write live in the shared rules gem,
  # so the monolith's local owner coerces "7" and If-Match exactly as this
  # service does. This module forwards to the gem and adds the agent check,
  # which the gem's EntryDecision does not offer.
  module EntryDecision
    extend SingleForwardable

    def_delegators TimekeepingRules::EntryDecision, :target_user, :version, :change, :bulk

    module_function

    # S7 for the agent and user a write will commit. EntryCommand has already
    # checked agent_id is nil or a positive Integer, so it passes unchanged.
    def agent_owner(agent_id:, user_id:, company_agents:)
      TimekeepingRules::EntryRules.agent_owner(agent_id:, user_id:, company_agents:)
    end
  end
end
