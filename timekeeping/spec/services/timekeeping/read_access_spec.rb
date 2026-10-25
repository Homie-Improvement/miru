# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::ReadAccess do
  let(:user) { Timekeeping::Identity.new(kind: :user, status: :verified, user_id: 7, company_id: 1, role: "admin") }

  it "allows a verified user on their own company's path" do
    expect(described_class.decide(user, path_company_id: "1")).to eq(:allowed)
  end

  it "answers not_found for another company's path, whatever the role" do
    expect(described_class.decide(user, path_company_id: "2")).to eq(:not_found)
    expect(described_class.decide(user, path_company_id: "01")).to eq(:not_found)
    expect(described_class.decide(user, path_company_id: "abc")).to eq(:not_found)
  end

  it "answers unauthorized for every identity that is not a verified user" do
    [
      Timekeeping::Identity.anonymous(:missing),
      Timekeeping::Identity.anonymous(:invalid),
      Timekeeping::Identity.anonymous(:expired),
      Timekeeping::Identity.service
    ].each do |identity|
      expect(described_class.decide(identity, path_company_id: "1")).to eq(:unauthorized)
    end
  end
end
