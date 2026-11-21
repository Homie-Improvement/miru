# frozen_string_literal: true

require "date"

RSpec.describe TimekeepingRules::EntryRules, "caller handling" do
  let(:today) { Date.new(2026, 3, 10) }
  let(:entry) { { id: 1, user_id: 1, work_date: today, bill_status: "unbilled", locked: false } }
  let(:inputs) { { change: { action: :update }, role: "employee", primary_role: "employee", acting_user_id: 1, edit_days: 7, today: } }

  [nil, :agent, "user_delegated", :"reservations.commit", "reservations.comit", false, "entries.import"].each do |unknown|
    context "with caller #{unknown.inspect}" do
      it "raises UnknownCaller from change_decision" do
        expect { described_class.change_decision(caller: unknown, entry:, **inputs) }
          .to raise_error(TimekeepingRules::EntryRules::UnknownCaller)
      end

      it "raises UnknownCaller from refusing_rules" do
        expect { described_class.refusing_rules(caller: unknown, entry:, **inputs) }
          .to raise_error(TimekeepingRules::EntryRules::UnknownCaller)
      end

      it "raises UnknownCaller from bulk_decision, even with no entries" do
        expect { described_class.bulk_decision(caller: unknown, entries: [], **inputs.merge(change: { action: :move })) }
          .to raise_error(TimekeepingRules::EntryRules::UnknownCaller)
      end
    end
  end

  it "raises UnknownCaller as an ArgumentError" do
    expect(TimekeepingRules::EntryRules::UnknownCaller.ancestors).to include(ArgumentError)
  end

  it "accepts every remaining background operation as a caller of change_decision" do
    TimekeepingRules::EntryRules::BACKGROUND_OPERATIONS.each do |operation|
      expect(described_class.change_decision(caller: operation, entry:, **inputs)).to eq(:ok)
    end
  end

  it "accepts a user-delegated caller" do
    expect(described_class.change_decision(caller: :user_delegated, entry:, **inputs)).to eq(:ok)
  end

  it "keeps entries.import out of the frozen background allowlist so no caller can append it at runtime" do
    operations = TimekeepingRules::EntryRules::BACKGROUND_OPERATIONS

    expect(operations).to eq(%w[
      reservations.prepare
      reservations.commit
      reservations.abort
      invoices.mark_billed
      agents.detach_entries
    ])
    expect(operations).to be_frozen
    expect(operations).to all(be_frozen)
    expect { operations << "entries.import" }.to raise_error(FrozenError)
  end

  # No caller mints entries.import, so a caller holding it must not keep the background skip of
  # the lock, staleness and ownership rules on an entry those rules would refuse.
  context "with the removed operation entries.import" do
    let(:background) { inputs.merge(role: nil, primary_role: nil, acting_user_id: nil) }

    it "refuses entries.import as an unknown caller on a locked, stale, foreign entry instead of skipping the user rules" do
      foreign = { id: 9, user_id: 2, work_date: today - 30, bill_status: "unbilled", locked: true }

      expect { described_class.change_decision(caller: "entries.import", entry: foreign, **background) }
        .to raise_error(TimekeepingRules::EntryRules::UnknownCaller)
    end

    it "refuses entries.import from refusing_rules rather than reporting a background rule set" do
      billed = entry.merge(bill_status: "billed", locked: true)

      expect do
        described_class.refusing_rules(caller: "entries.import", entry: billed,
                                       **inputs.merge(change: { action: :update, bill_status: "unbilled" }))
      end.to raise_error(TimekeepingRules::EntryRules::UnknownCaller)
    end

    it "refuses an entries.import bulk move of a locked entry before deciding any entry" do
      locked = entry.merge(id: 10, user_id: 2, locked: true)

      expect do
        described_class.bulk_decision(caller: "entries.import", entries: [locked],
                                      **background.merge(change: { action: :move }))
      end.to raise_error(TimekeepingRules::EntryRules::UnknownCaller)
    end
  end
end
