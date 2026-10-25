# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::Preflight do
  def preflight_entry(id, locked:)
    { id:, locked: }
  end

  def preflight_link(entry_id, invoice_id, draft: false, discarded: false)
    { entry_id:, invoice_id:, draft:, discarded: }
  end

  def preflight_lists_of(entry_id, result)
    described_class::LISTS.select do |list|
      result[list].any? { |item| item == entry_id || (item.is_a?(Hash) && item[:entry_id] == entry_id) }
    end
  end

  def classify_one(entry, links)
    described_class.classify(entries: [entry], links:)
  end

  it "puts a locked entry on one kept invoice in active, and the same entry unlocked in unlocked_links" do
    links = [preflight_link(1, 10)]

    locked = classify_one(preflight_entry(1, locked: true), links)
    unlocked = classify_one(preflight_entry(1, locked: false), links)

    expect(locked[:active]).to eq([1])
    expect(preflight_lists_of(1, locked)).to eq([:active])
    expect(unlocked[:unlocked_links]).to eq([{ entry_id: 1, invoice_id: 10 }])
    expect(preflight_lists_of(1, unlocked)).to eq([:unlocked_links])
  end

  it "retains a locked entry held only by a discarded non-draft, but not when a kept invoice also holds it" do
    discarded_non_draft = preflight_link(1, 10, discarded: true)

    held_only = classify_one(preflight_entry(1, locked: true), [discarded_non_draft])
    also_kept = classify_one(preflight_entry(1, locked: true), [discarded_non_draft, preflight_link(1, 11)])

    expect(held_only[:retained]).to eq([1])
    expect(preflight_lists_of(1, held_only)).to eq([:retained])
    expect(preflight_lists_of(1, also_kept)).to eq([:active])
  end

  it "releases a locked entry held only by a discarded draft, but not when a kept invoice also holds it" do
    discarded_draft = preflight_link(1, 10, draft: true, discarded: true)

    relocked = classify_one(preflight_entry(1, locked: true), [discarded_draft])
    also_kept = classify_one(preflight_entry(1, locked: true), [discarded_draft, preflight_link(1, 11)])

    expect(relocked[:relock_releases]).to eq([1])
    expect(preflight_lists_of(1, relocked)).to eq([:relock_releases])
    expect(preflight_lists_of(1, also_kept)).to eq([:active])
  end

  it "lists a locked entry that no invoice references as an orphan" do
    result = classify_one(preflight_entry(1, locked: true), [])

    expect(result[:orphans]).to eq([1])
    expect(preflight_lists_of(1, result)).to eq([:orphans])
  end

  it "lists an entry referenced by two kept invoices as a conflict, locked or not" do
    links = [preflight_link(1, 10), preflight_link(1, 11)]

    expect(preflight_lists_of(1, classify_one(preflight_entry(1, locked: true), links))).to eq([:conflicts])
    expect(preflight_lists_of(1, classify_one(preflight_entry(1, locked: false), links))).to eq([:conflicts])
  end

  it "lists an entry held by two discarded non-drafts and no kept invoice as a conflict, locked or not" do
    links = [preflight_link(1, 10, discarded: true), preflight_link(1, 11, discarded: true)]

    expect(preflight_lists_of(1, classify_one(preflight_entry(1, locked: true), links))).to eq([:conflicts])
    expect(preflight_lists_of(1, classify_one(preflight_entry(1, locked: false), links))).to eq([:conflicts])
  end

  it "puts an unlocked entry with one discarded link in no list" do
    non_draft = classify_one(preflight_entry(1, locked: false), [preflight_link(1, 10, discarded: true)])
    draft = classify_one(preflight_entry(1, locked: false), [preflight_link(1, 10, draft: true, discarded: true)])

    expect(preflight_lists_of(1, non_draft)).to be_empty
    expect(preflight_lists_of(1, draft)).to be_empty
  end

  it "counts a direct and a grouped link to the same invoice as one owner" do
    direct_and_grouped = [preflight_link(1, 10), preflight_link(1, 10)]

    result = classify_one(preflight_entry(1, locked: false), direct_and_grouped)

    expect(result[:unlocked_links]).to eq([{ entry_id: 1, invoice_id: 10 }])
    expect(result[:conflicts]).to be_empty
  end

  it "classifies several entries independently" do
    entries = [preflight_entry(1, locked: true), preflight_entry(2, locked: false), preflight_entry(3, locked: true)]
    links = [preflight_link(1, 10), preflight_link(2, 10)]

    result = described_class.classify(entries:, links:)

    expect(result).to eq(
      active: [1],
      orphans: [3],
      conflicts: [],
      retained: [],
      relock_releases: [],
      unlocked_links: [{ entry_id: 2, invoice_id: 10 }]
    )
  end

  it "returns six empty lists for empty inputs" do
    expect(described_class.classify(entries: [], links: [])).to eq(
      active: [], orphans: [], conflicts: [], retained: [], relock_releases: [], unlocked_links: []
    )
  end

  it "reads no database" do
    allow(ActiveRecord::Base).to receive(:connection).and_raise("classify must not touch the database")

    result = classify_one(preflight_entry(1, locked: true), [preflight_link(1, 10)])

    expect(result[:active]).to eq([1])
  end
end
