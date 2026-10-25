# frozen_string_literal: true

module TimekeepingContract
  # The prepare decision table of docs/architecture/timekeeping-soa.md
  # section 7.2, as data. For each entry in an invoice's desired set, the
  # first row whose condition holds gives the outcome.
  #
  # The fake keeps its own copy of the table only until the shared reservation
  # library that section 7.2 describes exists.
  module ReservationRules
    PREPARE_TABLE = [
      [->(entry) { !entry[:in_company] }, :not_found],
      [->(entry) { entry[:provisional] }, :provisional_elsewhere],
      [->(entry) { entry[:committed]&.fetch(:invoice_id) == entry[:invoice_id] }, :keep],
      [->(entry) { entry[:committed]&.fetch(:disposition) == "active" }, :on_another_invoice],
      [->(_entry) { true }, :add_provisional]
    ].freeze

    REFUSALS = %i[not_found provisional_elsewhere on_another_invoice].freeze

    module_function

    # entry: { in_company:, committed:, provisional:, invoice_id: }, where
    # committed and provisional are the entry's current reservations or nil.
    def prepare_outcome(entry)
      PREPARE_TABLE.find { |condition, _outcome| condition.call(entry) }.last
    end

    def refusal?(outcome)
      REFUSALS.include?(outcome)
    end
  end
end
