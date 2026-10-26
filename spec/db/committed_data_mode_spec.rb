# frozen_string_literal: true

require "rails_helper"

# The examples run in the order written: the later ones check what the
# earlier ones left behind.
RSpec.describe "Committed-data test mode", committed_data: true, order: :defined do
  it "commits rows that a second database connection can read" do
    invoice = create(:invoice)

    seen_elsewhere = committed_data_thread { Invoice.where(id: invoice.id).exists? }.value

    expect(seen_elsewhere).to be(true)
  end

  it "starts the next example with no committed invoice left behind" do
    expect(Invoice.count).to eq(0)
  end

  it "lets an example set a handoff step on the ownership row" do
    TimekeepingOwnership.current.update!(handoff_step: "close_admission")

    seen_elsewhere = committed_data_thread { TimekeepingOwnership.current.handoff_step }.value

    expect(seen_elsewhere).to eq("close_admission")
  end

  it "restores the ownership row with no handoff step for the next example" do
    expect(TimekeepingOwnership.current).to have_attributes(handoff_step: nil, generation: 1, owner: "monolith")
  end
end
