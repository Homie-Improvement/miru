# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::WriteAccess do
  let(:user) { Timekeeping::Identity.new(kind: :user, status: :verified, user_id: 7, company_id: 1, role: "employee") }

  it "allows a verified user on their own company's path" do
    expect(described_class.decide(user, path_company_id: "1")).to eq(:allowed)
  end

  it "answers reference_unavailable for an expired token, whatever the path company" do
    expired = Timekeeping::Identity.anonymous(:expired)

    %w[1 2 abc].push(nil).each do |path_company_id|
      expect(described_class.decide(expired, path_company_id:)).to eq(:reference_unavailable)
    end
  end

  it "answers unauthorized for a missing or invalid token and for the service identity" do
    [
      Timekeeping::Identity.anonymous(:missing),
      Timekeeping::Identity.anonymous(:invalid),
      Timekeeping::Identity.service
    ].each do |identity|
      expect(described_class.decide(identity, path_company_id: "1")).to eq(:unauthorized)
    end
  end

  it "answers not_found for a verified user on another company's path" do
    expect(described_class.decide(user, path_company_id: "2")).to eq(:not_found)
  end
end
