# frozen_string_literal: true

module Invoices
  # Chooses the reservation adapter for the store that owns entries now.
  module ReservationAdapters
    TABLE = {
      legacy: -> { LegacyReservations.new },
      prepared: -> { PreparedReservations.new },
      timekeeping: -> { Timekeeping::ReservationClient.build }
    }.freeze

    module_function

    def for(ownership)
      TABLE.fetch(Timekeeping::EntryOwner.for(ownership)).call
    end
  end
end
