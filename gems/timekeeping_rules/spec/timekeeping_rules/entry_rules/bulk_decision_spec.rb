# frozen_string_literal: true

require "date"

RSpec.describe TimekeepingRules::EntryRules, ".bulk_decision" do
  let(:today) { Date.new(2026, 3, 10) }

  def entry(id:, **overrides)
    { id:, user_id: 1, work_date: today, bill_status: "unbilled", locked: false }.merge(overrides)
  end

  def decide(entries:, action: :move, caller: :user_delegated, role: "employee", acting_user_id: 1)
    described_class.bulk_decision(caller:, change: { action: }, role:, acting_user_id:, entries:, edit_days: 7, today:)
  end

  let(:locked) { entry(id: 10, locked: true) }
  let(:free) { entry(id: 11) }

  it "skips an employee's locked entry and applies the free one on a move" do
    expect(decide(entries: [locked, free])).to eq(10 => :skip, 11 => :apply)
  end

  it "applies both entries for an admin move" do
    expect(decide(entries: [locked, free], role: "admin")).to eq(10 => :apply, 11 => :apply)
  end

  it "applies an employee's bulk delete of their own locked entry" do
    expect(decide(entries: [locked], action: :delete)).to eq(10 => :apply)
  end

  it "refuses the whole request when a billed own entry comes last" do
    billed = entry(id: 12, bill_status: "billed")
    expect(decide(entries: [free, billed])).to eq(:forbidden)
    expect(decide(entries: [free, billed], role: "admin")).to eq(:forbidden)
    expect(decide(entries: [free, billed], action: :delete, role: "owner")).to eq(:forbidden)
  end

  it "refuses an employee's request when a stale entry comes last, but not an admin's" do
    stale = entry(id: 13, work_date: today - 8)
    expect(decide(entries: [free, stale])).to eq(:forbidden)
    expect(decide(entries: [free, stale], role: "admin")).to eq(11 => :apply, 13 => :apply)
  end

  it "refuses an employee's request that includes a colleague's entry" do
    expect(decide(entries: [free, entry(id: 14, user_id: 2)])).to eq(:forbidden)
  end

  it "refuses a background bulk move or delete that includes a billed entry" do
    billed = entry(id: 12, bill_status: "billed")
    background = { caller: "reservations.abort", role: nil, acting_user_id: nil }
    expect(decide(entries: [free, billed], **background)).to eq(:forbidden)
    expect(decide(entries: [free, billed], action: :delete, **background)).to eq(:forbidden)
  end

  it "applies a background move of a locked entry" do
    expect(decide(entries: [locked], caller: "entries.import", role: nil, acting_user_id: nil)).to eq(10 => :apply)
  end

  it "refuses the whole request when a refused copy of a repeated id comes first or last" do
    {
      billed: entry(id: 11, bill_status: "billed"),
      stale: entry(id: 11, work_date: today - 8),
      foreign: entry(id: 11, user_id: 2)
    }.each_value do |refused|
      expect(decide(entries: [refused, free])).to eq(:forbidden)
      expect(decide(entries: [free, refused])).to eq(:forbidden)
    end
  end

  it "skips a repeated id when either copy is locked, in both orders" do
    locked_copy = entry(id: 11, locked: true)
    expect(decide(entries: [locked_copy, free])).to eq(11 => :skip)
    expect(decide(entries: [free, locked_copy])).to eq(11 => :skip)
  end

  it "raises on an action bulk does not support" do
    expect { decide(entries: [free], action: :update) }.to raise_error(ArgumentError)
  end
end
