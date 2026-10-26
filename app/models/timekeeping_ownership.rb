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

  INITIAL_GENERATION = 1
  INITIAL_OWNER = "monolith"
  INITIAL_MONOLITH_STORE = "legacy"

  # Raised by writers that may run only before any handoff has begun, such as
  # the seed and demo-data builders.
  class HandoffBegun < StandardError
    def initialize(msg = "A Timekeeping handoff has begun; seed and demo data can no longer be written. " \
                         "Reseeding needs a fresh demo reset.")
      super
    end
  end

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

  # Whether a handoff has begun. A missing row counts as begun: lost ownership
  # state must refuse writers, so this reads the row and never creates it.
  def self.handoff_begun?
    begun?(find_by(id: SINGLETON_ID))
  end

  # Raises HandoffBegun once a handoff has begun; returns nil otherwise.
  def self.refuse_if_handoff_begun!
    raise HandoffBegun if handoff_begun?

    nil
  end

  # Runs the block in a transaction only while no handoff has begun, and says
  # whether it ran. The row is read FOR SHARE in that same transaction, so a
  # handoff update waits until the block commits, and a call queued behind an
  # uncommitted handoff update sees the begun row and skips the block.
  def self.unless_handoff_begun
    transaction do
      next false if begun?(lock("FOR SHARE").find_by(id: SINGLETON_ID))

      yield
      true
    end
  end

  def self.begun?(ownership)
    ownership.nil? || ownership.handoff_begun?
  end
  private_class_method :begun?

  # True once the generation has been raised or any other column leaves its
  # initial value. The flip clears handoff_step, and an aborted handoff leaves
  # the legacy store at a raised generation, so handoff_step alone cannot
  # tell. An owner or store value other than the initial one counts as begun,
  # known or not.
  def handoff_begun?
    generation > INITIAL_GENERATION ||
      !handoff_step.nil? ||
      owner != INITIAL_OWNER ||
      monolith_store != INITIAL_MONOLITH_STORE
  end

  # Whether the projection consumer may apply a snapshot of this generation
  # (section 5.4). The current generation is always accepted. The previous
  # one is accepted only during a handoff, and only up to the final outbox
  # position captured at the freeze. Before this handoff reaches the freeze
  # step, a position left from an earlier handoff is not this handoff's P, so
  # nothing of the previous generation is accepted; nor is it without a
  # captured position. The flip, which clears handoff_step, ends the permission.
  def snapshot_generation_accepted?(generation:, outbox_position:)
    return true if generation == self.generation
    return false unless generation == self.generation - 1
    return false unless frozen_for_handoff? && !final_outbox_position.nil?

    outbox_position.is_a?(Integer) && outbox_position <= final_outbox_position
  end

  private

    # Whether the current handoff has reached the freeze step or a later one.
    def frozen_for_handoff?
      step_index = HANDOFF_STEPS.index(handoff_step)
      !step_index.nil? && step_index >= HANDOFF_STEPS.index("freeze")
    end
end
