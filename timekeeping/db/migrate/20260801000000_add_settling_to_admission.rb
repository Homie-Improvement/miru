# frozen_string_literal: true

# During a handoff's settle step the outgoing owner, though fenced, still
# applies a commit or abort it registered at the old generation, so no
# prepared operation is left unresolved. settling_generation names that old
# generation while the step is open; null means no step is open.
# settling_stopped_generation is the highest generation whose step was
# stopped. A timed-out request can still run on the server later, and this
# mark keeps a late settle from reopening a stopped step. Both are bigint,
# like the other generation columns.
class AddSettlingToAdmission < ActiveRecord::Migration[8.1]
  def change
    add_column :admission, :settling_generation, :bigint
    add_column :admission, :settling_stopped_generation, :bigint
  end
end
