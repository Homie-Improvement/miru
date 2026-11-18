# frozen_string_literal: true

# Runs the suite with the Timekeeping ownership row in one named state, chosen
# by TIMEKEEPING_OWNER_STATE, so the regression, guard and integration suites
# can prove behaviour under each owner without running a handoff.
#
# The cleaners in spec/support/database_cleaner.rb and
# spec/support/committed_data.rb put the row back to its column defaults
# (legacy) after they empty tables. spec/rails_helper.rb requires support files
# in sorted order, so the hook below is registered after theirs and re-applies
# the state before every example. With the variable unset, nothing is
# registered and the suite runs as before.
module TimekeepingOwnerState
  ENV_KEY = "TIMEKEEPING_OWNER_STATE"

  # One fixed time, so every run writes the same row. A rollback follows a
  # cutover from legacy, so it keeps the legacy table retired.
  LEGACY_RETIRED_AT = Time.utc(2026, 1, 1).freeze

  # Every ownership column of each state, plus the generation the Timekeeping
  # admission row holds in that state: nil for rollback, because the retired
  # Timekeeping owner admits no generation (docs/architecture/timekeeping-soa.md
  # section 10.5).
  STATES = {
    "legacy" => {
      owner: "monolith", monolith_store: "legacy", generation: 1, legacy_retired_at: nil,
      handoff_step: nil, final_outbox_position: nil, admission_generation: 1
    }.freeze,
    "timekeeping" => {
      owner: "timekeeping", monolith_store: "legacy", generation: 2, legacy_retired_at: LEGACY_RETIRED_AT,
      handoff_step: nil, final_outbox_position: nil, admission_generation: 2
    }.freeze,
    "rollback" => {
      owner: "monolith", monolith_store: "prepared", generation: 3, legacy_retired_at: LEGACY_RETIRED_AT,
      handoff_step: nil, final_outbox_position: nil, admission_generation: nil
    }.freeze
  }.freeze

  OWNERSHIP_COLUMNS = %i[owner monolith_store generation legacy_retired_at handoff_step final_outbox_position].freeze

  # The state assumed when none is selected: the row the cleaners leave.
  DEFAULT_STATE = "legacy"

  module_function

  # The state's columns; raises ArgumentError naming the valid states for any
  # other value, nil included.
  def fetch(state_name)
    STATES.fetch(state_name) do
      raise ArgumentError, "unknown Timekeeping owner state #{state_name.inspect}; " \
                           "expected one of #{STATES.keys.join(', ')}"
    end
  end

  # The selected state name, or nil only when the key is absent. The value
  # must match a state name exactly: a blank, padded or mixed-case value is a
  # mistake to report, not a request for the default.
  def selected(env)
    return nil unless env.key?(ENV_KEY)

    value = env[ENV_KEY]
    fetch(value)
    value
  end

  # Writes every ownership column of the state to row 1, creating the row
  # first when it is missing. ensure_initial! leaves an existing row as it is,
  # so the row is always updated afterwards.
  def apply!(state_name)
    columns = fetch(state_name).slice(*OWNERSHIP_COLUMNS)
    TimekeepingOwnership.ensure_initial!
    TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID).update_all(columns)
    nil
  end

  SELECTED = selected(ENV)

  module Expectations
    # Asserts the stored row is in the state. EntryOwner.for cannot tell
    # generations apart, so the owner columns, generation and whether the
    # legacy table is retired are compared too.
    def expect_owner_state!(state_name = TimekeepingOwnerState::SELECTED || TimekeepingOwnerState::DEFAULT_STATE)
      columns = TimekeepingOwnerState.fetch(state_name)
      expected = TimekeepingOwnership.new(columns.slice(*TimekeepingOwnerState::OWNERSHIP_COLUMNS))

      expect(owner_state_summary(TimekeepingOwnership.current)).to eq(owner_state_summary(expected))
    end

    private

      def owner_state_summary(ownership)
        {
          entry_owner: Timekeeping::EntryOwner.for(ownership),
          owner: ownership.owner,
          monolith_store: ownership.monolith_store,
          generation: ownership.generation,
          legacy_retired: !ownership.legacy_retired_at.nil?
        }
      end
  end
end

RSpec.configure do |config|
  config.include TimekeepingOwnerState::Expectations

  if TimekeepingOwnerState::SELECTED
    config.before do
      TimekeepingOwnerState.apply!(TimekeepingOwnerState::SELECTED)
    end
  end
end
