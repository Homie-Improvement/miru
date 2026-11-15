# frozen_string_literal: true

module Invoices
  # Chooses the reservation adapter for the store that owns entries now.
  # An owner with no adapter registered in the table answers with a
  # retryable error until its adapter is added.
  module ReservationAdapters
    TABLE = {
      legacy: -> { LegacyReservations.new },
      prepared: -> { PreparedReservations.new },
      timekeeping: -> { Timekeeping::ReservationClient.new(http: Timekeeping::ReservationHttp.new) }
    }.freeze

    module_function

    def for(ownership)
      TABLE.fetch(Timekeeping::EntryOwner.for(ownership)) { raise OperationErrors::AdapterNotAvailable }.call
    end
  end
end
