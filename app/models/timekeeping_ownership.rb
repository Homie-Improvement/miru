# frozen_string_literal: true

# The one record that says which application owns timesheet entries, at which
# generation, and which handoff step is in progress, if any
# (docs/architecture/timekeeping-soa.md section 10.1). It is global, not per
# company. The database allows only the row with id 1, and its column defaults
# hold the initial state: generation 1, owned by the monolith from its legacy
# timesheet_entries table, no handoff step.
class TimekeepingOwnership < ApplicationRecord
  self.table_name = "timekeeping_ownership"

  SINGLETON_ID = 1
  OWNERS = %w[monolith timekeeping].freeze
  HANDOFF_STEPS = %w[close_admission settle freeze checkpoint sequence reconcile].freeze
  MONOLITH_STORES = %w[legacy prepared].freeze

  validates :generation, presence: true
  validates :owner, inclusion: { in: OWNERS }
  validates :handoff_step, inclusion: { in: HANDOFF_STEPS }, allow_nil: true
  validates :monolith_store, inclusion: { in: MONOLITH_STORES }

  # Raises ActiveRecord::RecordNotFound when the row is missing, so a caller
  # never mistakes lost ownership state for a fresh monolith-owned start.
  def self.current
    find(SINGLETON_ID)
  end

  # Creates the initial row from the column defaults when the table is empty,
  # and leaves an existing row unchanged. A database loaded from db/schema.rb
  # has no rows, so database setup and the test suite call this; the S2
  # migration inserts the same row on databases that migrate.
  def self.ensure_initial!
    insert_all([{ id: SINGLETON_ID }], unique_by: :id)
  end

  # Whether the projection consumer may apply a snapshot of this generation
  # (section 5.4). The current generation is always accepted. The previous
  # one is accepted only during a handoff, and only up to the final outbox
  # position captured at the freeze. Without a captured position nothing of
  # the previous generation is accepted, and the flip, which clears
  # handoff_step, ends the permission.
  def snapshot_generation_accepted?(generation:, outbox_position:)
    return true if generation == self.generation
    return false unless generation == self.generation - 1
    return false if handoff_step.nil? || final_outbox_position.nil?

    outbox_position.is_a?(Integer) && outbox_position <= final_outbox_position
  end
end
