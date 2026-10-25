# frozen_string_literal: true

module TimekeepingRules
  # The timesheet entry rules A1 to A11 of docs/architecture/timekeeping-soa.md
  # section 2.1, as pure functions over plain values. Each function returns a
  # symbol (or the acting user's id) and reads no clock, database or Rails
  # state, so the monolith and the Timekeeping service decide alike.
  module EntryRules
    # Matches privileged_roles in contracts/timekeeping/entry_api.yml. Every
    # other role, an unknown one included, is non-privileged.
    PRIVILEGED_ROLES = %w[owner admin].freeze

    # A5: whom a create request's user_id names, in order. The first row whose
    # condition holds decides, the same order as TARGET_USER_TABLE in
    # spec/support/timekeeping/fake_timekeeping.rb. Ids are compared without
    # coercion, so "7" never matches 7.
    TARGET_USER_TABLE = [
      [->(request) { request[:requested_user_id].nil? || request[:requested_user_id] == request[:acting_user_id] }, :acting],
      [->(request) { !request[:privileged] }, :forbidden],
      [->(request) { !request[:company_user_ids].include?(request[:requested_user_id]) }, :not_found],
      [->(_request) { true }, :requested]
    ].freeze

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

    # A1: :company when the caller sees every kept entry of the company,
    # otherwise the user id whose entries the caller may see.
    def visible_scope(role:, acting_user_id:)
      return :company if privileged?(role)

      # A nil id must never reach a query as "no user filter".
      raise ArgumentError, "acting_user_id must be an Integer, got #{acting_user_id.inspect}" unless acting_user_id.is_a?(Integer)

      acting_user_id
    end

    def privileged?(role)
      # A Symbol such as :owner would otherwise fall silently to non-privileged.
      raise ArgumentError, "role must be a String, got #{role.inspect}" unless role.is_a?(String)

      PRIVILEGED_ROLES.include?(role)
    end
    private_class_method :privileged?
  end
end
