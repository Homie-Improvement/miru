# frozen_string_literal: true

# Run by spec/meta/timekeeping_regression_spec.rb through
# TimekeepingDemo::Regression in its own rspec processes. The name does not end
# in _spec.rb, so a normal suite run never loads it. The tagged example fails
# whenever an owner state is set, so a state run that executed it would fail.
require "rails_helper"

RSpec.describe "Timekeeping regression switches_owner probe", order: :defined do
  it "runs in every ownership state" do
    expect(TimekeepingOwnerState::ENV_KEY).to eq("TIMEKEEPING_OWNER_STATE")
  end

  it "runs only in the separate switches_owner pass", :switches_owner do
    expect(ENV.fetch(TimekeepingOwnerState::ENV_KEY, nil)).to be_nil
  end
end
