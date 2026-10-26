# frozen_string_literal: true

module Timekeeping
  # A row of the prepared monolith's entries table
  # (docs/architecture/timekeeping-soa.md section 10.1), the one model over
  # that table. Timekeeping::LocalOwner writes it; Timekeeping::EntryReader
  # reads it while the monolith owns entries from its prepared store.
  class LocalEntry < ApplicationRecord
    self.table_name = "entries"

    # An entry is locked exactly when a reservation row exists for it in the
    # same company. The stored entries.locked column is never kept current, so
    # it is never read for this.
    RESERVED = <<~SQL.squish
      EXISTS (
        SELECT 1 FROM reservations
        WHERE reservations.company_id = entries.company_id
          AND reservations.entry_id = entries.id
      ) AS reserved
    SQL

    # Every column plus the reservation flag as `reserved`. A writer runs this
    # as its own statement after taking its row locks: a statement that waited
    # on a lock still evaluates the subquery against the snapshot taken before
    # the wait, so it would miss a reservation the lock holder just committed.
    def self.with_reserved
      select("entries.*", RESERVED)
    end
  end
end
