# frozen_string_literal: true

RSpec.describe TimekeepingRules::EntryRules, ".target_user" do
  def decide(role:, requested_user_id:, acting_user_id: 1, company_user_ids: [1, 2, 3])
    described_class.target_user(acting_user_id:, role:, requested_user_id:, company_user_ids:)
  end

  it "loads without Rails or ActiveRecord" do
    expect(defined?(Rails)).to be_nil
    expect(defined?(ActiveRecord)).to be_nil
  end

  it "refuses an employee naming a colleague" do
    expect(decide(role: "employee", requested_user_id: 2)).to eq(:forbidden)
  end

  it "refuses an employee naming a user outside the company as forbidden, not not_found" do
    expect(decide(role: "employee", requested_user_id: 99)).to eq(:forbidden)
  end

  it "refuses any non-privileged role naming a colleague" do
    expect(decide(role: "book_keeper", requested_user_id: 2)).to eq(:forbidden)
  end

  it "answers not_found when an admin names a user outside the company" do
    expect(decide(role: "admin", requested_user_id: 99)).to eq(:not_found)
  end

  it "answers not_found when an id differs only in type from a company id" do
    expect(decide(role: "owner", requested_user_id: "2")).to eq(:not_found)
  end

  it "records the entry for a same-company user an owner names" do
    expect(decide(role: "owner", requested_user_id: 2)).to eq(:requested)
  end

  it "records the entry for a same-company user an admin names" do
    expect(decide(role: "admin", requested_user_id: 3)).to eq(:requested)
  end

  it "acts for an owner naming themselves even when company_user_ids is empty" do
    expect(decide(role: "owner", requested_user_id: 1, company_user_ids: [])).to eq(:acting)
  end

  it "acts for an employee naming themselves" do
    expect(decide(role: "employee", requested_user_id: 1)).to eq(:acting)
  end

  it "acts for an employee naming no one" do
    expect(decide(role: "employee", requested_user_id: nil)).to eq(:acting)
  end

  it "raises when the role is not a String" do
    expect { decide(role: :owner, requested_user_id: 2) }.to raise_error(ArgumentError)
  end
end
