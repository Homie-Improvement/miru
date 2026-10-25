# frozen_string_literal: true

# The one record that says which application owns timesheet entries, at which
# generation, and which handoff step is in progress, if any
# (docs/architecture/timekeeping-soa.md section 10.1). It is global, not per
# company. The database allows only the row with id 1, and its column defaults
# hold the initial state: generation 1, owned by the monolith, no handoff step.
class TimekeepingOwnership < ApplicationRecord
  self.table_name = "timekeeping_ownership"

  SINGLETON_ID = 1
  OWNERS = %w[monolith timekeeping].freeze
  HANDOFF_STEPS = %w[close_admission settle freeze checkpoint sequence reconcile].freeze

  validates :generation, presence: true
  validates :owner, inclusion: { in: OWNERS }
  validates :handoff_step, inclusion: { in: HANDOFF_STEPS }, allow_nil: true

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
end
