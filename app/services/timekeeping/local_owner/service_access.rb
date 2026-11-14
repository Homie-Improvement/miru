# frozen_string_literal: true

module Timekeeping
  class LocalOwner
    # Decides, before any lock or read, whether an actor may run a service
    # route on the local owner. Only a service actor passes, only for an
    # operation it holds that is also a named background operation, and only
    # for the company it is bound to. Mirrors the Timekeeping service's
    # Timekeeping::ReservationAccess.
    #
    # A company other than the actor's answers :not_found, the same as a
    # missing id, so a caller cannot tell whether another company exists.
    module ServiceAccess
      # The operation each route runs, as a signed service token spells it.
      ROUTE_OPERATIONS = {
        prepare: "reservations.prepare",
        commit: "reservations.commit",
        abort: "reservations.abort",
        mark_billed: "invoices.mark_billed",
        detach_entries: ServiceToken::DETACH_ENTRIES
      }.freeze

      # In order: the first row whose condition holds decides.
      RULES = [
        [->(access) { access[:actor].nil? }, :unauthorized],
        [->(access) { access[:actor].kind != :service }, :forbidden],
        [->(access) { !granted_operations(access[:actor]).include?(ROUTE_OPERATIONS[access[:operation]]) }, :forbidden],
        [->(access) { !same_company?(access[:actor].company_id, access[:company_id]) }, :not_found],
        [->(_access) { true }, :ok]
      ].map(&:freeze).freeze

      module_function

      def call(actor:, operation:, company_id:)
        access = { actor:, operation: operation.to_sym, company_id: }
        RULES.find { |condition, _answer| condition.call(access) }.last
      end

      # A token can name any string, so only the names the background
      # allowlist also holds grant anything.
      def granted_operations(actor)
        actor.operations & TimekeepingRules::EntryRules::BACKGROUND_OPERATIONS
      end

      # Compared as ids, so 7 and "7" match, while nil, "" or anything that
      # is not an id never matches, not even another missing value.
      def same_company?(actor_company_id, company_id)
        actor_id = company_id_value(actor_company_id)
        !actor_id.nil? && actor_id == company_id_value(company_id)
      end

      def company_id_value(value)
        Integer(value.to_s, 10) if TimekeepingRules::EntryDecision::ID.match?(value.to_s)
      end
    end
  end
end
