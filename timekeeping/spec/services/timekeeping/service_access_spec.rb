# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::ServiceAccess do
  it "allows the service identity" do
    expect(described_class.decide(Timekeeping::Identity.service)).to eq(:allowed)
  end

  it "refuses verified users of every role" do
    %w[owner admin employee].each do |role|
      user = Timekeeping::Identity.new(kind: :user, status: :verified, user_id: 7, company_id: 1, role:)

      expect([role, described_class.decide(user)]).to eq([role, :unauthorized])
    end
  end

  it "refuses missing, invalid and expired tokens" do
    [
      Timekeeping::Identity.anonymous(:missing),
      Timekeeping::Identity.anonymous(:invalid),
      Timekeeping::Identity.anonymous(:expired, signed_company_id: 1)
    ].each do |identity|
      expect(described_class.decide(identity)).to eq(:unauthorized)
    end
  end
end
