# frozen_string_literal: true

module Timekeeping
  # Which store holds the authoritative entries right now
  # (docs/architecture/timekeeping-soa.md sections 3.3 and 10.1): Timekeeping,
  # the prepared monolith's local tables, or the legacy timesheet_entries.
  #
  # The generation cannot tell legacy from prepared, because every handoff
  # raises it and an aborted one keeps it. So the monolith's side is read from
  # the stored monolith_store marker. During a handoff the owner column still
  # names the outgoing owner, which still holds the data.
  module EntryOwner
    module_function

    # Returns :timekeeping, :legacy or :prepared.
    def for(ownership)
      return :timekeeping if ownership.owner == "timekeeping"

      ownership.monolith_store.to_sym
    end
  end
end
