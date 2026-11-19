# frozen_string_literal: true

# Records when the monolith's admission adapter fenced its writers
# (docs/architecture/timekeeping-soa.md section 10.5 step 1). Setting it takes
# the exclusive lock on the ownership row, so it waits for writers holding the
# row FOR SHARE, and every writer that reads the row afterwards is refused.
# Closing admission clears it in the same update that sets handoff_step.
class AddAdmissionFencedAtToTimekeepingOwnership < ActiveRecord::Migration[8.1]
  def change
    add_column :timekeeping_ownership, :admission_fenced_at, :datetime
  end
end
