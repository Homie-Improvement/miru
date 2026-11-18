# frozen_string_literal: true

# Run by spec/meta/timekeeping_owner_state_spec.rb in its own rspec process
# with TIMEKEEPING_OWNER_STATE unset. The row is set to the rollback state
# before any per-example hook runs; the example passes only when no hook from
# spec/support/timekeeping/owner_state.rb rewrites it.
require "rails_helper"

RSpec.describe "Timekeeping owner state probe with no state selected" do
  before(:all) { TimekeepingOwnerState.apply!("rollback") }

  after(:all) do
    TimekeepingOwnership.delete_all
    TimekeepingOwnership.ensure_initial!
  end

  it "leaves the ownership row as the example arranged it" do
    expect(TimekeepingOwnerState::SELECTED).to be_nil
    expect_owner_state!("rollback")
  end
end
