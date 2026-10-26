# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Timekeeping::Gateway refusal types" do
  it "refuses entry writes with a subclass of the billing refusal, so existing 503 handling catches it" do
    expect(Timekeeping::Gateway::OwnershipMoving.new).to be_a(Timekeeping::BillingFence::OwnershipMoving)
    expect(Timekeeping::Gateway::OwnershipMoving.new).not_to be_a(ActiveRecord::RecordInvalid)
    expect(Timekeeping::Gateway::OwnershipMoving.new.message).to eq("ownership_moving")
  end

  it "raises a stale generation refusal that is not a validation error" do
    expect(Timekeeping::Gateway::StaleGeneration.new).not_to be_a(ActiveRecord::RecordInvalid)
    expect(Timekeeping::Gateway::StaleGeneration.new.message).to eq("stale_generation")
  end

  it "refuses every local-owner call by default as a retryable ownership move" do
    local_owner = Timekeeping::Gateway::UnavailableLocalOwner.new

    %i[find_entry create_entry update_entry destroy_entry].each do |method|
      expect { local_owner.public_send(method, context: nil) }.to raise_error(Timekeeping::Gateway::OwnershipMoving)
    end
  end
end
