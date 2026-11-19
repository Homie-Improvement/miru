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

  # What a settle step transition reads under the row lock.
  PhaseState = Data.define(:handoff_step, :settling_generation, :settling_stopped_generation)

  # The settle step's transitions, as pure functions of the locked row. Each
  # returns the column changes to write, or nil when the call changes
  # nothing. A stop mark at or above a generation means that generation's
  # step was stopped and must stay stopped.
  module SettlingPhase
    # Opens only during a handoff, never at or below the stop mark, and never
    # over a step that is already open at the same or a newer generation.
    def self.begin(state, generation)
      return if state.handoff_step.nil?
      return unless state.settling_stopped_generation.nil? || state.settling_stopped_generation < generation
      return unless state.settling_generation.nil? || state.settling_generation < generation

      { settling_generation: generation }
    end

    # Always ends the open step and raises the mark to generation; the mark
    # never falls.
    def self.stop(state, generation)
      { settling_generation: nil,
        settling_stopped_generation: [state.settling_stopped_generation, generation].compact.max }
    end

    # Ends whatever step is open and raises the mark to that step's
    # generation, for transitions such as a flip or an abort that end the
    # handoff without stop_applying!. Without the raised mark, a late begin
    # during a later handoff could reopen the old generation. With no step
    # open the mark stays as it is.
    def self.close(state)
      stop(state, state.settling_generation)
    end
  end

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

  # Opens the settle step of a handoff for the outgoing generation: while it
  # is open, the monolith still applies a commit or abort it registered at
  # that generation (docs/architecture/timekeeping-soa.md section 10.5 step
  # 2). A late or repeated call never reopens a stopped step or replaces a
  # newer one (SettlingPhase.begin).
  def self.begin_settling!(generation:)
    change_settling_phase!(generation) { |state| SettlingPhase.begin(state, generation) }
  end

  # Ends the settle step and raises the stop mark to generation. The update
  # waits for every commit or abort holding the row FOR SHARE, so none of
  # them applies after this returns.
  def self.stop_applying!(generation:)
    change_settling_phase!(generation) { |state| SettlingPhase.stop(state, generation) }
  end

  # Whether a settle step is open. false when the row is missing.
  def self.settling?
    !where(id: SINGLETON_ID).pick(:settling_generation).nil?
  end

  def self.change_settling_phase!(generation)
    check_generation!(generation)

    transaction do
      row = lock.where(id: SINGLETON_ID).pick(:handoff_step, :settling_generation, :settling_stopped_generation)
      raise ActiveRecord::RecordNotFound.new("timekeeping_ownership row is missing", name, primary_key, SINGLETON_ID) if row.nil?

      changes = yield PhaseState.new(*row)
      where(id: SINGLETON_ID).update_all(changes) if changes
    end
  end
  private_class_method :change_settling_phase!

  # A nil or non-Integer generation could never match a stored generation, so
  # it is refused before the row is touched.
  def self.check_generation!(generation)
    raise ArgumentError, "generation must be a positive Integer" unless generation.is_a?(Integer) && generation.positive?
  end
  private_class_method :check_generation!

  # True once the generation has been raised or any other column leaves its
  # initial value. The flip clears handoff_step, and an aborted handoff leaves
  # the legacy store at a raised generation, so handoff_step alone cannot
  # tell. An owner or store value other than the initial one counts as begun,
  # known or not.
  #
  # The admission fence mark counts too: the fence is the handoff's first
  # write and leaves every other column initial, so without it the seeds and
  # the user hard delete would run while the monolith's own writers are
  # refused. An abort's admit clears the mark; if close_admission never
  # raised the generation, nothing has moved and the row is initial again.
  def handoff_begun?
    generation > INITIAL_GENERATION ||
      !handoff_step.nil? ||
      owner != INITIAL_OWNER ||
      monolith_store != INITIAL_MONOLITH_STORE ||
      !admission_fenced_at.nil?
  end

  # Assigns SettlingPhase.close's changes to this record without saving, for
  # a caller that already holds the row lock and saves it in its own write.
  def close_settling_step
    assign_attributes(SettlingPhase.close(PhaseState.new(handoff_step:, settling_generation:,
                                                         settling_stopped_generation:)))
  end

  # Whether the monolith's entry and billing writers must refuse. A handoff
  # step closes admission, and so does the admission adapter's fence mark,
  # which is set before close_admission records its step.
  def admission_closed?
    !handoff_step.nil? || !admission_fenced_at.nil?
  end

  # Whether the handoff source is the legacy timesheet_entries table, which is
  # what makes a handoff run the pre-flight and derive reservations. Only the
  # flip of a handoff from the legacy source sets legacy_retired_at. The
  # generation cannot answer this: an aborted first cutover keeps the raised
  # generation while the legacy table is still the source.
  def source_legacy?
    legacy_retired_at.nil?
  end

  # Whether the projection consumer may apply a snapshot of this generation
  # (section 5.4). The current generation is always accepted. The previous
  # one is accepted only during a handoff, and only up to the final outbox
  # position P. The freeze step stores P before it drains the outbox and
  # records 'freeze' only after the drain, so the stored P, not the recorded
  # step, opens the permission. Closing admission clears P, so a position
  # left from an earlier handoff never counts as this handoff's. The flip and
  # an abort, which clear handoff_step, end the permission.
  def snapshot_generation_accepted?(generation:, outbox_position:)
    return true if generation == self.generation
    return false unless generation == self.generation - 1
    return false if handoff_step.nil? || final_outbox_position.nil?

    outbox_position.is_a?(Integer) && outbox_position <= final_outbox_position
  end
end
