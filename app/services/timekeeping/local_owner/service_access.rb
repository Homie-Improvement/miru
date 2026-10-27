# frozen_string_literal: true

module Timekeeping
  class LocalOwner
    # Decides, before any lock, read or write, whether an actor may call a
    # reservation route or service command on the local owner. Only a service
    # actor passes, and only for the company it is bound to and for an
    # operation it was granted that is also one of the named background
    # operations. The Timekeeping service decides the same way in
    # Timekeeping::ReservationAccess, which this application does not load.
    #
    # A company other than the actor's answers :not_found, the same as a
    # missing id, so a caller cannot tell whether another company exists.
    module ServiceAccess
      # The operation each route runs, as an actor's operations spell it.
      ROUTE_OPERATIONS = {
        prepare: "reservations.prepare",
        commit: "reservations.commit",
        abort: "reservations.abort",
        mark_billed: "invoices.mark_billed",
        detach_entries: "agents.detach_entries"
      }.freeze

      # In order: the first row whose condition holds decides.
      RULES = [
        [->(access) { access[:actor].nil? }, :unauthorized],
        [->(access) { access[:actor].kind != :service }, :forbidden],
        [->(access) { !granted_operations(access[:actor]).include?(ROUTE_OPERATIONS.fetch(access[:route])) }, :forbidden],
        [->(access) { access[:actor].company_id.to_s != access[:company_id].to_s }, :not_found],
        [->(_access) { true }, :allowed]
      ].map(&:freeze).freeze

      module_function

      def routes
        ROUTE_OPERATIONS.keys
      end

      def decide(actor:, company_id:, route:)
        access = { actor:, company_id:, route: route.to_sym }
        RULES.find { |condition, _decision| condition.call(access) }.last
      end

      # An actor can carry any string, so only the names the background
      # allowlist also holds grant anything.
      def granted_operations(actor)
        actor.operations & TimekeepingRules::EntryRules::BACKGROUND_OPERATIONS
      end
    end
  end
end
