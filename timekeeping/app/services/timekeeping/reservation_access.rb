# frozen_string_literal: true

module Timekeeping
  # Decides, before any read or write, whether a request may call a
  # reservation route or service command. Only a signed service token passes,
  # and only for the company its verified claims name and for an operation it
  # lists that is also one of the named background operations. The raw shared
  # TIMEKEEPING_SERVICE_TOKEN lists no operation, so it is refused here.
  #
  # A path company other than the token's answers :not_found, the same as a
  # missing id, so a caller cannot tell whether another company exists.
  module ReservationAccess
    # The operation each route runs, as a token's operations claim spells it.
    ROUTE_OPERATIONS = {
      prepare: "reservations.prepare",
      commit: "reservations.commit",
      abort: "reservations.abort",
      mark_billed: "invoices.mark_billed",
      detach_entries: "agents.detach_entries"
    }.freeze

    # In order: the first row whose condition holds decides.
    RULES = [
      [->(access) { access[:identity].status != :verified }, :unauthorized],
      [->(access) { access[:identity].kind != :service }, :forbidden],
      [->(access) { !granted_operations(access[:identity]).include?(access[:operation]) }, :forbidden],
      [->(access) { access[:identity].company_id.to_s != access[:company_id].to_s }, :not_found],
      [->(_access) { true }, :allowed]
    ].map(&:freeze).freeze

    module_function

    def decide(identity:, company_id:, operation:)
      access = { identity:, company_id:, operation: }
      RULES.find { |condition, _decision| condition.call(access) }.last
    end

    # A token can name any string, so only the names the background allowlist
    # also holds grant anything.
    def granted_operations(identity)
      identity.operations & TimekeepingRules::EntryRules::BACKGROUND_OPERATIONS
    end
  end
end
