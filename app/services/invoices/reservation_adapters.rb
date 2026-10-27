# frozen_string_literal: true

module Invoices
  # Chooses the reservation adapter for the store that owns entries now.
  # An owner with no adapter registered yet answers with a retryable error
  # until its adapter is added to the table.
  module ReservationAdapters
    NOT_AVAILABLE = -> { raise OperationErrors::AdapterNotAvailable }

    TABLE = {
      legacy: -> { LegacyReservations.new },
      prepared: NOT_AVAILABLE,
      timekeeping: NOT_AVAILABLE
    }.freeze

    module_function

    def for(ownership)
      TABLE.fetch(Timekeeping::EntryOwner.for(ownership)).call
    end
  end
end
