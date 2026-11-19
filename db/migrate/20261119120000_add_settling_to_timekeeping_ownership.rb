# frozen_string_literal: true

# Stores the monolith's settle step of a handoff away from it
# (docs/architecture/timekeeping-soa.md section 10.5 steps 2 and 3).
# settling_generation is the outgoing generation whose registered commits and
# aborts the monolith still applies; settling_stopped_generation is the highest
# generation whose step was stopped, so a late call cannot reopen it. Both are
# bigint because they hold copies of the bigint generation column, and both
# start NULL: no step is open and none was stopped.
class AddSettlingToTimekeepingOwnership < ActiveRecord::Migration[8.1]
  def change
    add_column :timekeeping_ownership, :settling_generation, :bigint
    add_column :timekeeping_ownership, :settling_stopped_generation, :bigint
  end
end
