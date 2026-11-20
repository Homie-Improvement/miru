# frozen_string_literal: true

# Run by spec/meta/timekeeping_regression_spec.rb through
# TimekeepingDemo::Regression in a temporary app tree whose .env.test.local
# names an owner state and sets TIMEKEEPING_DOTENV_PROBE=loaded. The name does
# not end in _spec.rb, so a normal suite run never loads it.
#
# Each example first checks that this child booted from that tree and read
# its dotenv file, so a pass never rests on the file being ignored.
require "rails_helper"

RSpec.describe "Timekeeping dotenv owner state probe", order: :defined do
  def expect_dotenv_tree_loaded!
    expect(ENV.fetch("TIMEKEEPING_DOTENV_PROBE", nil)).to eq("loaded")
    expect(Rails.root.to_s).to start_with(ENV.fetch("TIMEKEEPING_DOTENV_TREE"))
  end

  it "keeps the state the regression command gives a state pass" do
    expect_dotenv_tree_loaded!
    expect(TimekeepingOwnerState::SELECTED).to eq("legacy")
  end

  context "in the switches_owner pass", :switches_owner do
    before(:all) { TimekeepingOwnerState.apply!("rollback") }

    after(:all) do
      TimekeepingOwnership.delete_all
      TimekeepingOwnership.ensure_initial!
    end

    it "selects no owner state and leaves the ownership row as the example arranged it" do
      expect_dotenv_tree_loaded!
      expect(TimekeepingOwnerState::SELECTED).to be_nil
      expect_owner_state!("rollback")
    end
  end
end
