# frozen_string_literal: true

require "yaml"

module Timekeeping
  # The prepare decision table of docs/architecture/timekeeping-soa.md
  # section 7.2, as data. For each entry in an invoice's desired set, the
  # first row whose condition holds gives the outcome. The not-in-company row
  # comes first, so the answer for another company's entry never says whether
  # or where it is reserved.
  #
  # This is the only copy of the table: the fake Timekeeping in the contract
  # specs reads it from here.
  module ReservationRules
    PREPARE_TABLE = [
      [->(entry) { !entry[:in_company] }, :not_found],
      [->(entry) { entry[:provisional] }, :provisional_elsewhere],
      [->(entry) { entry[:committed]&.fetch(:invoice_id) == entry[:invoice_id] }, :keep],
      [->(entry) { entry[:committed]&.fetch(:disposition) == "active" }, :on_another_invoice],
      [->(_entry) { true }, :add_provisional]
    ].map(&:freeze).freeze

    # The outcomes that refuse a prepare, as the reservations contract lists them.
    # Read relative to this file, so the fakes the Timekeeping service and the
    # relay gem load from spec/support find the contract without this app.
    REFUSALS = YAML.safe_load_file(File.expand_path("../../../contracts/timekeeping/reservations.yml", __dir__))
      .fetch("conflict_reasons").map(&:to_sym).freeze

    module_function

    # entry: { in_company:, committed:, provisional:, invoice_id: }, where
    # committed and provisional are the entry's current reservations or nil.
    # table lets the contract mutation spec run the fake with a changed copy.
    def prepare_outcome(entry, table: PREPARE_TABLE)
      table.find { |condition, _outcome| condition.call(entry) }.last
    end

    def refusal?(outcome)
      REFUSALS.include?(outcome)
    end
  end
end
