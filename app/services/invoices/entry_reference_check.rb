# frozen_string_literal: true

module Invoices
  # Where the entries an invoice line names are checked for existence and
  # company, by the store that owns entries now
  # (docs/architecture/timekeeping-soa.md section 6.3, rule L8).
  #
  # While the monolith owns entries, the timesheet_entries table is its own
  # data, so a row missing there really is missing. Once Timekeeping owns
  # them, that table is a projection that lags behind the relay, so only
  # Timekeeping's prepare answer can say whether an entry exists and which
  # company holds it.
  module EntryReferenceCheck
    SOURCES = {
      legacy: :projection,
      prepared: :projection,
      timekeeping: :prepare_response
    }.freeze

    module_function

    # Raises KeyError for an owner with no row, so a new owner cannot skip
    # the check by default.
    def source_for(owner)
      SOURCES.fetch(owner)
    end

    def for(ownership)
      source_for(Timekeeping::EntryOwner.for(ownership))
    end
  end
end
