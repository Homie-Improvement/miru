# frozen_string_literal: true

# The Timekeeping service and the relay gem load these fakes without this
# app's autoloader, so they need the rules file required directly.
require_relative "../../../app/services/timekeeping/reservation_rules" unless defined?(Timekeeping::ReservationRules)

module TimekeepingContract
  # The fake reads the app's prepare decision table, so the fake and the app
  # share one copy of docs/architecture/timekeeping-soa.md section 7.2.
  ReservationRules = ::Timekeeping::ReservationRules
end
