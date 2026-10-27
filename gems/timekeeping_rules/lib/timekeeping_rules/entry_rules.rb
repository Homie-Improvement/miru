# frozen_string_literal: true

module TimekeepingRules
  # The timesheet entry rules A1 to A11 of docs/architecture/timekeeping-soa.md
  # section 2.1, as pure functions over plain values. Each function returns a
  # symbol (or the acting user's id) and reads no clock, database or Rails
  # state, so the monolith and the Timekeeping service decide alike.
  module EntryRules
    # Raised for any caller: value outside USER_DELEGATED and
    # BACKGROUND_OPERATIONS, so a missing or misspelled caller can never be
    # read as a background caller and skip A6 and A7.
    class UnknownCaller < ArgumentError; end

    # Matches privileged_roles in contracts/timekeeping/entry_api.yml. Every
    # other role, an unknown one included, is non-privileged.
    PRIVILEGED_ROLES = %w[owner admin].freeze

    # A6 and A7 bind only this primary role, as the model's validations do
    # today: they compare the user's lowest-id role in the company
    # (User#primary_role), not the owner or admin role a token may carry.
    EMPLOYEE_ROLE = "employee"
    BILLED = "billed"

    USER_DELEGATED = :user_delegated
    # The named background operations of section 6.2, spelled as there.
    BACKGROUND_OPERATIONS = %w[
      reservations.prepare
      reservations.commit
      reservations.abort
      invoices.mark_billed
      entries.import
      agents.detach_entries
    ].freeze

    # The review status a new entry starts with: an entry an agent recorded
    # waits for a person to review it, as TimesheetEntry gives it on save.
    PENDING_REVIEW = "pending_review"
    REVIEW_NOT_REQUIRED = "not_required"

    CHANGE_ACTIONS = %i[update delete].freeze
    BULK_ACTIONS = %i[move delete].freeze
    ACTIONS = (CHANGE_ACTIONS | BULK_ACTIONS).freeze

    # Refusal rules as [rule id, binds, refuses]. A rule refuses a change when
    # both conditions hold for the change's facts. A2 binds every caller, so a
    # billed entry is never changed or deleted. A3, A4, A6 and A7 rest on the
    # user's role and id, so they bind user-delegated callers only; that is
    # the A8 skip, granted to named background operations. A10 is A6 not
    # binding deletes. A11 is the absence of any rule guarding a change to
    # billed.
    CHANGE_RULES = [
      [:a2, ->(_facts) { true }, ->(facts) { facts[:billed] }],
      [:a3, ->(facts) { facts[:user_delegated] }, ->(facts) { !facts[:privileged] && facts[:stale] }],
      [:a4, ->(facts) { facts[:user_delegated] }, ->(facts) { !facts[:privileged] && !facts[:own] }],
      [:a6, ->(facts) { facts[:user_delegated] && facts[:action] != :delete }, ->(facts) { facts[:employee] && facts[:locked] }],
      [:a7, ->(facts) { facts[:user_delegated] && facts[:action] == :update }, ->(facts) { facts[:employee] && facts[:leaves_billed] }]
    ].map(&:freeze).freeze

    # A9: a bulk request containing an entry these rules refuse is refused
    # whole. An entry refused by any other rule (A6) is skipped on its own.
    WHOLE_REQUEST_RULES = %i[a2 a3 a4].freeze

    # A5: whom a create request's user_id names, in order. The first row whose
    # condition holds decides, the same order as TARGET_USER_TABLE in
    # spec/support/timekeeping/fake_timekeeping.rb. Ids are compared without
    # coercion, so "7" never matches 7.
    TARGET_USER_TABLE = [
      [->(request) { request[:requested_user_id].nil? || request[:requested_user_id] == request[:acting_user_id] }, :acting],
      [->(request) { !request[:privileged] }, :forbidden],
      [->(request) { !request[:company_user_ids].include?(request[:requested_user_id]) }, :not_found],
      [->(_request) { true }, :requested]
    ].map(&:freeze).freeze

    # S7: whether an entry may carry an agent, in order. company_agents maps
    # each agent id of the entry's company to its user id. An unknown agent
    # and another user's agent answer alike, as the contract's company
    # mismatch rule asks, so the answer never shows whether the agent exists
    # elsewhere. Ids are compared without coercion, so "7" never matches 7.
    AGENT_OWNER_TABLE = [
      [->(request) { request[:agent_id].nil? }, :ok],
      [->(request) { !request[:company_agents].key?(request[:agent_id]) }, :not_found],
      [->(request) { request[:company_agents].fetch(request[:agent_id]) != request[:user_id] }, :not_found],
      [->(_request) { true }, :ok]
    ].map(&:freeze).freeze

    module_function

    # A5: :acting records the entry for the caller, :requested for the named
    # same-company user; :forbidden and :not_found refuse the request.
    def target_user(acting_user_id:, role:, requested_user_id:, company_user_ids:)
      request = {
        acting_user_id:,
        requested_user_id:,
        company_user_ids:,
        privileged: privileged?(role)
      }
      TARGET_USER_TABLE.find { |condition, _outcome| condition.call(request) }.last
    end

    # S7: :ok when the entry has no agent, or its agent is one of the
    # company's and belongs to user_id, the entry's user after the write;
    # otherwise :not_found.
    def agent_owner(agent_id:, user_id:, company_agents:)
      request = { agent_id:, user_id:, company_agents: }
      AGENT_OWNER_TABLE.find { |condition, _outcome| condition.call(request) }.last
    end

    # The review status every owning store gives a created entry. It is never
    # read from the request, so no caller can mark its own entry reviewed.
    def created_review_status(agent_id:)
      agent_id.nil? ? REVIEW_NOT_REQUIRED : PENDING_REVIEW
    end

    # A1: :company when the caller sees every kept entry of the company,
    # otherwise the user id whose entries the caller may see.
    def visible_scope(role:, acting_user_id:)
      return :company if privileged?(role)

      # A nil id must never reach a query as "no user filter".
      raise ArgumentError, "acting_user_id must be an Integer, got #{acting_user_id.inspect}" unless acting_user_id.is_a?(Integer)

      acting_user_id
    end

    # The ids of every rule in CHANGE_RULES that refuses this change of one
    # entry, in table order. change: is { action: :update | :delete | :move,
    # bill_status: new status or nil }; entry: is { id:, user_id:, work_date:,
    # bill_status:, locked: }. role decides A3 and A4; primary_role, the
    # user's lowest-id role in the company, decides A6 and A7. primary_role
    # has no default, so no caller can fall back to a raised role for them.
    def refusing_rules(caller:, change:, role:, primary_role:, acting_user_id:, entry:, edit_days:, today:)
      check_caller!(caller)
      check_action!(change, ACTIONS)
      facts = change_facts(caller:, change:, role:, primary_role:, acting_user_id:, entry:, edit_days:, today:)
      CHANGE_RULES.filter_map { |rule_id, binds, refuses| rule_id if binds.call(facts) && refuses.call(facts) }
    end

    # A2 to A4, A6, A7, A10, A11 for an update or delete of one entry.
    def change_decision(caller:, change:, role:, primary_role:, acting_user_id:, entry:, edit_days:, today:)
      check_caller!(caller)
      check_action!(change, CHANGE_ACTIONS)
      refusals = refusing_rules(caller:, change:, role:, primary_role:, acting_user_id:, entry:, edit_days:, today:)
      refusals.empty? ? :ok : :forbidden
    end

    # A9: a bulk move or delete. Every entry is judged before any result is
    # returned, so one refused entry refuses the whole request wherever it
    # sits in the list. Entries are judged before they are keyed by id, so an
    # id listed twice cannot hide a refusal; it is skipped if either copy is.
    def bulk_decision(caller:, change:, role:, primary_role:, acting_user_id:, entries:, edit_days:, today:)
      check_caller!(caller)
      check_action!(change, BULK_ACTIONS)
      refusals = entries.map do |entry|
        [entry[:id], refusing_rules(caller:, change:, role:, primary_role:, acting_user_id:, entry:, edit_days:, today:)]
      end
      return :forbidden if refusals.any? { |_id, rules| rules.intersect?(WHOLE_REQUEST_RULES) }

      refusals.each_with_object({}) do |(id, rules), outcomes|
        outcomes[id] = rules.empty? && outcomes[id] != :skip ? :apply : :skip
      end
    end

    def change_facts(caller:, change:, role:, primary_role:, acting_user_id:, entry:, edit_days:, today:)
      user_delegated = caller == USER_DELEGATED
      # A background caller carries no role, so its role is never read.
      privileged = user_delegated && privileged?(role)
      new_bill_status = change[:bill_status]
      {
        action: change[:action],
        user_delegated:,
        privileged:,
        employee: user_delegated && primary_role == EMPLOYEE_ROLE,
        own: entry[:user_id] == acting_user_id,
        billed: entry[:bill_status] == BILLED,
        locked: entry[:locked] == true,
        leaves_billed: entry[:bill_status] == BILLED && !new_bill_status.nil? && new_bill_status != BILLED,
        stale: stale?(entry[:work_date], edit_days:, today:)
      }
    end
    private_class_method :change_facts

    # A3: older than the window by a strict less-than, as the policy's
    # stale check does, so the boundary day can still be changed. An entry
    # without a work date is never stale.
    def stale?(work_date, edit_days:, today:)
      !work_date.nil? && work_date < today - edit_days
    end
    private_class_method :stale?

    def check_caller!(caller)
      return if caller == USER_DELEGATED || BACKGROUND_OPERATIONS.include?(caller)

      raise UnknownCaller, "unknown caller #{caller.inspect}"
    end
    private_class_method :check_caller!

    def check_action!(change, allowed)
      return if allowed.include?(change[:action])

      raise ArgumentError, "change action must be one of #{allowed.inspect}, got #{change[:action].inspect}"
    end
    private_class_method :check_action!

    def privileged?(role)
      # A Symbol such as :owner would otherwise fall silently to non-privileged.
      raise ArgumentError, "role must be a String, got #{role.inspect}" unless role.is_a?(String)

      PRIVILEGED_ROLES.include?(role)
    end
    private_class_method :privileged?
  end
end
