# frozen_string_literal: true

module TimekeepingContract
  # The fake reads the app's prepare decision table, so the fake and the app
  # share one copy of docs/architecture/timekeeping-soa.md section 7.2.
  ReservationRules = ::Timekeeping::ReservationRules
end
