require "rails_helper"

RSpec.describe Timekeeping::LegacyCreateReplay do
  it "decision answers write with no receipt, replay for a matching fingerprint and key_reused for a different one" do
    identity = { "user_id" => 7, "project_id" => 3, "fields" => { "duration" => 30, "note" => "Timer" } }
    changed = { "user_id" => 7, "project_id" => 3, "fields" => { "duration" => 30, "note" => "Other" } }
    fingerprint = described_class.fingerprint(identity)

    expect(fingerprint).to be_a(String)
    expect(described_class.fingerprint(identity)).to eq(fingerprint)
    expect(described_class.fingerprint(changed)).not_to eq(fingerprint)
    expect(described_class.decision(stored_fingerprint: nil, fingerprint:)).to eq(:write)
    expect(described_class.decision(stored_fingerprint: fingerprint, fingerprint:)).to eq(:replay)
    expect(described_class.decision(stored_fingerprint: described_class.fingerprint(changed), fingerprint:))
      .to eq(:key_reused)
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LegacyCreateReplay do
  it "decision answers write with no receipt, replay on a matching fingerprint and key_reused on a different one" do
    stored = described_class.fingerprint({ "user_id" => 1, "project_id" => 2, "fields" => { "note" => "a" } })
    changed = described_class.fingerprint({ "user_id" => 1, "project_id" => 2, "fields" => { "note" => "b" } })

    expect(described_class.decision(stored_fingerprint: nil, fingerprint: stored)).to eq(:write)
    expect(described_class.decision(stored_fingerprint: stored, fingerprint: stored)).to eq(:replay)
    expect(described_class.decision(stored_fingerprint: stored, fingerprint: changed)).to eq(:key_reused)
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LegacyCreateReplay do
  it "fingerprint is stable for the same identity and changes when one request value changes" do
    identity = { "user_id" => 7, "project_id" => 9, "fields" => { "duration" => 30, "note" => "timer" } }
    other = { "user_id" => 7, "project_id" => 9, "fields" => { "duration" => 31, "note" => "timer" } }

    fingerprint = described_class.fingerprint(identity)

    expect(fingerprint).to be_a(String)
    expect(described_class.fingerprint(identity.deep_dup)).to eq(fingerprint)
    expect(described_class.fingerprint(other)).not_to eq(fingerprint)
  end
end
