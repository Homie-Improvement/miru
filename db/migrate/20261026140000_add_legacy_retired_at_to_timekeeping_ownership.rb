# frozen_string_literal: true

# Records when the legacy timesheet_entries table stopped being a handoff
# source (docs/architecture/timekeeping-soa.md section 10.5). The first
# cutover's flip sets it; while it is null the source is legacy, and the
# handoff runs the pre-flight and derives reservations. The generation cannot
# say this, because an aborted first cutover keeps the raised generation.
class AddLegacyRetiredAtToTimekeepingOwnership < ActiveRecord::Migration[8.1]
  def change
    add_column :timekeeping_ownership, :legacy_retired_at, :datetime
  end
end
