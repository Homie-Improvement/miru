# frozen_string_literal: true

RSpec.describe TimekeepingRules::EntryDecision, ".version" do
  it "never reads a non-numeric If-Match as version 0" do
    expect(described_class.version(if_match: "abc", current_version: 0)).to eq(:version_conflict)
  end

  it "accepts a matching numeric If-Match and a missing one" do
    expect(described_class.version(if_match: "3", current_version: 3)).to eq(:ok)
    expect(described_class.version(if_match: nil, current_version: 3)).to eq(:ok)
    expect(described_class.version(if_match: "2", current_version: 3)).to eq(:version_conflict)
  end
end
