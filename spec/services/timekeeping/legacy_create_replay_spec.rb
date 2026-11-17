# frozen_string_literal: true

require "rails_helper"
require "digest"

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

  it "fingerprint is stable for the same identity and changes when one request value changes" do
    identity = { "user_id" => 7, "project_id" => 9, "fields" => { "duration" => 30, "note" => "timer" } }
    other = { "user_id" => 7, "project_id" => 9, "fields" => { "duration" => 31, "note" => "timer" } }

    fingerprint = described_class.fingerprint(identity)

    expect(fingerprint).to be_a(String)
    expect(described_class.fingerprint(identity.deep_dup)).to eq(fingerprint)
    expect(described_class.fingerprint(other)).not_to eq(fingerprint)
  end
end

RSpec.describe Timekeeping::LegacyCreateReplay do
  # "A create whose first attempt committed in the legacy store with an Idempotency-Key, retried with the same key
  # and body after the first cutover flip, replays the original entry from Timekeeping, and the test shows no second
  # entry was recorded."
  # Two legacy creates by one user with one client key but different actor kinds both committed; if their carried
  # receipts shared a key, one retry would meet the other's receipt and be refused instead of replayed.
  it "carried_key keeps a browser and a command-line create under one client key apart from each other and from a create first made in Timekeeping" do
    client_key = "6b1d3f0e-2a4c-4e8f-9b7d-1c2e3f4a5b6c"

    user_key = described_class.carried_key(actor_kind: "user", key: client_key)
    cli_key = described_class.carried_key(actor_kind: "cli", key: client_key)
    forwarded_key = Timekeeping::EntryWriteClient.idempotency_key(request_id: client_key, operation: "create")

    expect(user_key).to be_a(String)
    expect(user_key).not_to eq(cli_key)
    expect([user_key, cli_key]).not_to include(forwarded_key)
    expect(described_class.carried_key(actor_kind: "user", key: client_key)).to eq(user_key)
  end

  # A client that sends a key shaped like a carried key's seed must still get a
  # key of its own, or Timekeeping would answer it from another create's receipt.
  it "carried_key is never the key a forwarded create derives from any client key, including one shaped like its seed" do
    client_key = "6b1d3f0e-2a4c-4e8f-9b7d-1c2e3f4a5b6c"
    carried = %w[user cli].map { |actor_kind| described_class.carried_key(actor_kind:, key: client_key) }
    crafted = ["legacy_create/user/#{client_key}", "legacy_create/cli/#{client_key}", "user/#{client_key}",
               "cli/#{client_key}"]

    derived = crafted.map do |crafted_key|
      Timekeeping::EntryWriteClient.idempotency_key(request_id: crafted_key, operation: "create")
    end

    expect(derived & carried).to be_empty
  end
end

RSpec.describe Timekeeping::LegacyCreateReplay do
  # "A create whose first attempt committed in the legacy store with an Idempotency-Key, retried with the same key
  # and body after the first cutover flip, replays the original entry from Timekeeping, and the test shows no second
  # entry was recorded."
  # Timekeeping hashes the body it parses and regenerates, so the carried fingerprint must match that hash exactly:
  # formatting in the stored text must not change it, while the serialized key order must.
  it "forwarded_fingerprint ignores whitespace in the stored body but changes when the key order changes" do
    compact = '{"duration":30.0,"note":"Timer","project_id":3,"user_id":7}'
    spaced = '{ "duration": 30.0, "note": "Timer", "project_id": 3, "user_id": 7 }'
    reordered = '{"note":"Timer","duration":30.0,"project_id":3,"user_id":7}'

    expected = Digest::SHA256.hexdigest(JSON.generate(JSON.parse(compact)))

    expect(described_class.forwarded_fingerprint(compact)).to eq(expected)
    expect(described_class.forwarded_fingerprint(spaced)).to eq(expected)
    expect(described_class.forwarded_fingerprint(reordered)).not_to eq(expected)
  end
end
