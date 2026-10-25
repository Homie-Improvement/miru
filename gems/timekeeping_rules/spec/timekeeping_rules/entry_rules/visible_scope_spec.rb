# frozen_string_literal: true

RSpec.describe TimekeepingRules::EntryRules, ".visible_scope" do
  it "lets an owner see the whole company" do
    expect(described_class.visible_scope(role: "owner", acting_user_id: 1)).to eq(:company)
  end

  it "lets an admin see the whole company" do
    expect(described_class.visible_scope(role: "admin", acting_user_id: 1)).to eq(:company)
  end

  it "limits an employee to their own entries" do
    expect(described_class.visible_scope(role: "employee", acting_user_id: 7)).to eq(7)
  end

  it "limits any other role to their own entries" do
    expect(described_class.visible_scope(role: "book_keeper", acting_user_id: 7)).to eq(7)
  end

  it "raises for a non-privileged caller with no user id" do
    expect { described_class.visible_scope(role: "employee", acting_user_id: nil) }.to raise_error(ArgumentError)
  end

  it "raises when the role is not a String" do
    expect { described_class.visible_scope(role: :owner, acting_user_id: 1) }.to raise_error(ArgumentError)
  end
end
