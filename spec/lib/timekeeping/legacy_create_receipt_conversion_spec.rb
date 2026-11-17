# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::LegacyCreateReceiptConversion do
  let(:captured_at) { Time.utc(2026, 11, 17, 12) }

  # One live, keyed legacy create receipt with a forwarded body and the committed entry it answers with. Examples
  # pass as keywords the values their assertions read; `overrides` replaces whole receipt fields, such as
  # forwarded_body or expires_at.
  def legacy_create_receipt(id:, entry_id:, key:, note: "n#{id}", company_id: 1, actor_kind: "user", **overrides)
    body = { "project_id" => 3, "duration" => 30.0, "work_date" => "2026-11-02", "note" => note,
             "bill_status" => "unbilled", "user_id" => 7, "source" => "manual", "source_metadata" => {} }
    entry_values = body.merge(
      "id" => entry_id, "company_id" => company_id, "version" => 0, "review_status" => "approved", "agent_id" => nil,
      "proof_url" => nil, "proof_metadata" => {}, "external_run_id" => nil, "external_session_id" => nil,
      "locked" => false
    )
    {
      id:, company_id:, actor_kind:, actor_id: 7, key:, forwarded_body: JSON.generate(body), entry_values:,
      created_at: captured_at - 3600, expires_at: captured_at + 3600
    }.merge(overrides)
  end

  it "receipts of two companies under one client key each convert into a row and answer scoped to their own company" do
    shared_key = "3f2a9c1e-7b4d-4e8f-9a0b-1c2d3e4f5a6b"
    receipts = [legacy_create_receipt(id: 1, entry_id: 501, key: shared_key, company_id: 1, note: "first company"),
                legacy_create_receipt(id: 2, entry_id: 502, key: shared_key, company_id: 2, note: "second company")]

    result = described_class.convert(receipts:, captured_at:)

    expect(result[:refusals]).to be_empty
    rows = result[:rows].sort_by { |row| row["id"] }
    expect(rows.pluck("company_id")).to eq([1, 2])
    # Each row's stored answer names only its own company and its own entry, so a key replayed
    # under one company never returns the other company's entry.
    rows.zip(receipts).each do |row, receipt|
      answer = JSON.parse(row["body"])
      expect(answer["company_id"]).to eq(receipt[:company_id])
      expect(answer["id"]).to eq(receipt[:entry_values]["id"])
      expect(answer["note"]).to eq(receipt[:entry_values]["note"])
    end
  end

  # "A create whose first attempt committed in the legacy store with an Idempotency-Key, retried with the same key
  # and body after the first cutover flip, replays the original entry from Timekeeping, and the test shows no second
  # entry was recorded."
  # A browser create and a command-line create by one user with one client key both committed in the legacy store;
  # dropping either receipt, or giving both one Timekeeping key, leaves one of the two retries unable to replay.
  it "convert carries both receipts that differ only by actor kind under distinct keys with their own fingerprints" do
    web = legacy_create_receipt(id: 1, entry_id: 501, key: "shared-client-key", actor_kind: "user",
                                note: "from the browser", created_at: captured_at - 3600 + 1)
    cli = legacy_create_receipt(id: 2, entry_id: 502, key: "shared-client-key", actor_kind: "cli",
                                note: "from the CLI", created_at: captured_at - 3600 + 2)

    result = described_class.convert(receipts: [web, cli], captured_at:)
    rows = result.fetch(:rows)

    expect(result.fetch(:refusals)).to be_empty
    expect(rows.size).to eq(2)
    by_id = rows.index_by { |row| row["id"] }
    expect(by_id.fetch(1)["key"])
      .to eq(Timekeeping::LegacyCreateReplay.carried_key(actor_kind: "user", key: "shared-client-key"))
    expect(by_id.fetch(2)["key"])
      .to eq(Timekeeping::LegacyCreateReplay.carried_key(actor_kind: "cli", key: "shared-client-key"))
    expect(by_id.fetch(1)["fingerprint"])
      .to eq(Timekeeping::LegacyCreateReplay.forwarded_fingerprint(web.fetch(:forwarded_body)))
    expect(by_id.fetch(2)["fingerprint"])
      .to eq(Timekeeping::LegacyCreateReplay.forwarded_fingerprint(cli.fetch(:forwarded_body)))
    expect(rows.map { |row| [row["company_id"], row["actor_type"], row["actor_id"], row["operation"]] }.uniq)
      .to eq([[1, "user", 7, "create "]])
    expect(JSON.parse(by_id.fetch(2)["body"])["note"]).to eq("from the CLI")
  end

  # "A create whose first attempt committed in the legacy store with an Idempotency-Key, retried with the same key
  # and body after the first cutover flip, replays the original entry from Timekeeping, and the test shows no second
  # entry was recorded."
  # A receipt written before the forwarded body was stored cannot be carried; skipping it quietly would let its retry
  # record a second entry after the flip, so the cutover must be refused while it can still be retried.
  it "convert refuses an unexpired receipt written without a forwarded body instead of silently leaving it behind" do
    live = legacy_create_receipt(
      id: 41, entry_id: 741, key: "key-41", company_id: 2, forwarded_body: nil, expires_at: captured_at + 60,
      entry_values: { "id" => 741, "company_id" => 2, "note" => "before the change" }, created_at: captured_at - 7200
    )
    expired = legacy_create_receipt(
      id: 42, entry_id: 742, key: "key-42", company_id: 3, forwarded_body: nil, expires_at: captured_at - 60,
      entry_values: { "id" => 742, "company_id" => 3, "note" => "before the change" }, created_at: captured_at - 7200
    )

    result = described_class.convert(receipts: [live, expired], captured_at:)

    expect(result.fetch(:rows)).to be_empty
    refusals = result.fetch(:refusals)
    expect(refusals.keys).to eq([2])
    expect(refusals.fetch(2).join(" ")).to include("41")
  end

  # "A create whose first attempt committed in the legacy store with an Idempotency-Key, retried with the same key
  # and body after the first cutover flip, replays the original entry from Timekeeping, and the test shows no second
  # entry was recorded."
  # The legacy store treats a receipt with expires_at at or before now as expired, so the checkpoint must use the same
  # boundary: carrying the expired one would revive a receipt the legacy store no longer answers.
  it "convert leaves out a receipt that expires exactly at the capture time and keeps one that expires a second later" do
    at_boundary = legacy_create_receipt(id: 1, entry_id: 801, key: "expiry-key-1", expires_at: captured_at)
    just_after = legacy_create_receipt(id: 2, entry_id: 802, key: "expiry-key-2", expires_at: captured_at + 1)

    result = described_class.convert(receipts: [at_boundary, just_after], captured_at:)

    expect(result.fetch(:refusals)).to be_empty
    expect(result.fetch(:rows).pluck("id")).to eq([2])
  end
end
