# frozen_string_literal: true

# Run by spec/meta/timekeeping_owner_state_spec.rb in its own rspec process
# with TIMEKEEPING_OWNER_STATE set. Its name does not end in _spec.rb, so a
# normal suite run never loads it. The second example runs after the
# committed_data cleaner has put the ownership row back to legacy, so it
# passes only when the selected state is re-applied.
require "rails_helper"

RSpec.describe "Timekeeping owner state probe", order: :defined do
  it "runs a committed_data example first", committed_data: true do
    expect(TimekeepingOwnership.current).to be_present
  end

  it "sees the selected owner state after the committed_data reset" do
    state = TimekeepingOwnerState.fetch(ENV.fetch("TIMEKEEPING_OWNER_STATE"))
    row = TimekeepingOwnership.current

    expect([row.owner, row.monolith_store, row.generation])
      .to eq([state[:owner], state[:monolith_store], state[:generation]])
    expect_owner_state!
  end
end
