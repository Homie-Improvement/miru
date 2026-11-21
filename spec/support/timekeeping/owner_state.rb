# frozen_string_literal: true

# Runs the suite with the Timekeeping ownership row in one named state, chosen
# by TIMEKEEPING_OWNER_STATE for the run or by an example's owner_state
# metadata, so the regression, guard and integration suites can prove
# behaviour under each owner without running a handoff.
#
# The cleaners in spec/support/database_cleaner.rb and
# spec/support/committed_data.rb put the row back to its column defaults
# (legacy) after they empty tables. spec/rails_helper.rb requires support files
# in sorted order, so the hook below is registered after theirs and re-applies
# the example's state before every example. When neither the variable nor the
# example names a state, the hook writes nothing and the suite runs as before.
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

  # Example metadata for specs that assert on writes forwarded to Timekeeping.
  # In a state where the monolith owns the entries nothing is forwarded, so
  # the hook below skips those examples with a stated reason.
  FORWARDS_TAG = :forwards_to_timekeeping

  # Example metadata for assertions on the legacy store's own mechanism, such
  # as a TimesheetEntry model callback or a stub of a legacy model write. They
  # mean nothing where another store owns the entries, so the hook below skips
  # them there with a stated reason.
  LEGACY_STORE_TAG = :writes_legacy_store

  # Each tag that limits an example to one owner: the Timekeeping::EntryOwner
  # value the example needs, and why it is skipped in a state without it.
  OWNER_TAGS = {
    FORWARDS_TAG => {
      owner: :timekeeping,
      reason: lambda { |state_name|
        "Writes are forwarded only when Timekeeping owns the entries; in the #{state_name} owner state " \
          "the monolith owns them and writes locally, which the local-write examples cover."
      }
    }.freeze,
    LEGACY_STORE_TAG => {
      owner: :legacy,
      reason: lambda { |state_name|
        "This checks the legacy store's own write path; in the #{state_name} owner state another store " \
          "owns the entries and the legacy model is never written."
      }
    }.freeze
  }.freeze

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
  # mistake to report, not a request for the default. In a regression child
  # (TIMEKEEPING_REGRESSION=1) an empty TIMEKEEPING_OWNER_STATE never reaches
  # SELECTED: config/application.rb removes it at boot, because the regression
  # command's switches_owner pass sets it to "" so that dotenv cannot fill it
  # from a local .env.
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

  # The state this run expects the row to be in: the selected one, or the
  # cleaners' default when none is selected.
  def current
    SELECTED || DEFAULT_STATE
  end

  # The state one example runs in: its owner_state metadata, else the state
  # selected for the run. nil when neither names one, so an unset run leaves
  # the row as the cleaners wrote it; any other unknown value raises.
  def for_example(metadata)
    state_name = metadata[:owner_state] || SELECTED
    return nil if state_name.nil?

    fetch(state_name)
    state_name
  end

  # The Timekeeping::EntryOwner value of the state: the rule the gateway
  # dispatches on, so no list of states per owner is kept here. Raises like
  # fetch for an unknown name, so a misspelt state fails instead of skipping.
  def entry_owner(state_name)
    columns = fetch(state_name).slice(*OWNERSHIP_COLUMNS)
    Timekeeping::EntryOwner.for(TimekeepingOwnership.new(columns))
  end

  # Whether the gateway forwards entry writes to Timekeeping in the state.
  def forwards_writes?(state_name)
    entry_owner(state_name) == :timekeeping
  end

  # Why an example cannot run in its state, or nil when it can. Only a tag in
  # OWNER_TAGS limits an example, and only in a selected state whose entry
  # owner differs from the one the tag needs. With no state selected the
  # example runs: the forwarding helper then hands ownership to Timekeeping,
  # and the cleaners leave the legacy store owning entries.
  def skip_reason(metadata)
    tags = OWNER_TAGS.select { |tag, _rule| metadata[tag] == true }
    return nil if tags.empty?

    state_name = for_example(metadata)
    return nil if state_name.nil?

    owner = entry_owner(state_name)
    tags.each_value.find { |rule| rule[:owner] != owner }&.then { |rule| rule[:reason].call(state_name) }
  end

  # skip_reason for the forwarding tag alone.
  def forwarding_skip_reason(metadata)
    skip_reason(metadata.slice(FORWARDS_TAG, :owner_state))
  end

  module Expectations
    # Asserts the stored row is in the state. EntryOwner.for cannot tell
    # generations apart, so the owner columns, generation and whether the
    # legacy table is retired are compared too.
    def expect_owner_state!(state_name = TimekeepingOwnerState.current)
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

  config.before do |example|
    state_name = TimekeepingOwnerState.for_example(example.metadata)
    TimekeepingOwnerState.apply!(state_name) if state_name
  end

  # Suite hooks run before group hooks, so a skipped example builds none of
  # its group's committed rows, fake registrations or HTTP routes.
  config.before do |example|
    reason = TimekeepingOwnerState.skip_reason(example.metadata)
    skip reason if reason
  end
end
