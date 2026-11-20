# frozen_string_literal: true

# Run by spec/meta/timekeeping_owner_state_spec.rb in its own rspec process as
# a regression child (TIMEKEEPING_REGRESSION=1) with TIMEKEEPING_OWNER_STATE
# set to "". Setting the key keeps dotenv from filling it from a local .env
# file, and config/application.rb deletes the empty value before the harness
# reads it, so no state is selected. The row is set to the rollback state
# before any per-example hook runs; the example passes only when no hook from
# spec/support/timekeeping/owner_state.rb rewrites it.
#
# When TIMEKEEPING_DOTENV_TREE is set, the run was started in a temporary app
# tree whose dotenv file names an owner state, and the example first checks
# that this child booted from that tree and read the file, so a pass never
# rests on the file being ignored.
require "rails_helper"

RSpec.describe "Timekeeping owner state probe with no state selected" do
  before(:all) { TimekeepingOwnerState.apply!("rollback") }

  after(:all) do
    TimekeepingOwnership.delete_all
    TimekeepingOwnership.ensure_initial!
  end

  it "leaves the ownership row as the example arranged it" do
    if ENV.key?("TIMEKEEPING_DOTENV_TREE")
      expect(ENV.fetch("TIMEKEEPING_DOTENV_PROBE", nil)).to eq("loaded")
      expect(Rails.root.to_s).to start_with(ENV.fetch("TIMEKEEPING_DOTENV_TREE"))
    end
    expect(TimekeepingOwnerState::SELECTED).to be_nil
    expect_owner_state!("rollback")
  end
end
