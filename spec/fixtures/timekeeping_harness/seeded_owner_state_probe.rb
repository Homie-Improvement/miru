# frozen_string_literal: true

# Run by spec/meta/timekeeping_owner_state_spec.rb in its own rspec process
# with TIMEKEEPING_OWNER_STATE set. Its name does not end in _spec.rb, so a
# normal suite run never loads it. The one example is both committed and
# seeded, so it passes only when the committed_data cleanup reloads the seed
# into an empty ownership table and applies the selected state afterwards: a
# seed loaded over a non-legacy row raises HandoffBegun.
require "rails_helper"

RSpec.describe "Timekeeping seeded owner state probe", :two_tenant_seed, committed_data: true do
  it "finds both seeded companies in the selected owner state" do
    expect(Company.find_by(name: "Fork & Leaf Salads")).to be_present
    expect(Company.find_by(name: "Copper Kettle Bakery")).to be_present
    expect(TimekeepingOwnership.count).to eq(1)
    expect_owner_state!(ENV.fetch("TIMEKEEPING_OWNER_STATE"))
  end
end
