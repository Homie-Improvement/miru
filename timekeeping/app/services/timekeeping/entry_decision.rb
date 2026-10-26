# frozen_string_literal: true

require "forwardable"

module Timekeeping
  # The request-value coercions of an entry write live in the shared rules gem,
  # so the monolith's local owner coerces "7" and If-Match exactly as this
  # service does. This module forwards to the gem and adds the agent check,
  # which the gem's EntryDecision does not offer. change and bulk call
  # EntryRules directly because they must pass the token's primary role,
  # which the gem's EntryDecision does not accept.
  module EntryDecision
    extend SingleForwardable

    def_delegators TimekeepingRules::EntryDecision, :target_user, :version

    module_function

    # S7 for the agent and user a write will commit. EntryCommand has already
    # checked agent_id is nil or a positive Integer, so it passes unchanged.
    def agent_owner(agent_id:, user_id:, company_agents:)
      TimekeepingRules::EntryRules.agent_owner(agent_id:, user_id:, company_agents:)
    end

    # A2 to A4, A6, A7 for an update or delete of one locked entry. entry: is
    # { id:, user_id:, work_date:, bill_status:, locked: }. primary_role is
    # the token's primary role, which decides A6 and A7.
    def change(action:, bill_status:, role:, primary_role:, acting_user_id:, entry:, edit_days:, today:)
      TimekeepingRules::EntryRules.change_decision(
        caller: TimekeepingRules::EntryRules::USER_DELEGATED,
        change: { action:, bill_status: },
        role:, primary_role:, acting_user_id:, entry:, edit_days:, today:
      )
    end

    # A9 for a bulk move or delete: :forbidden refuses the whole request,
    # otherwise each entry id maps to :apply or :skip (a move of a reserved
    # entry by a user whose primary role is employee). Only entries the caller
    # may see are passed in.
    def bulk(action:, role:, primary_role:, acting_user_id:, entries:, edit_days:, today:)
      TimekeepingRules::EntryRules.bulk_decision(
        caller: TimekeepingRules::EntryRules::USER_DELEGATED,
        change: { action: },
        role:, primary_role:, acting_user_id:, entries:, edit_days:, today:
      )
    end
  end
end
