# frozen_string_literal: true

require "date"

RSpec.describe TimekeepingRules::EntryRules, "caller handling" do
  let(:today) { Date.new(2026, 3, 10) }
  let(:entry) { { id: 1, user_id: 1, work_date: today, bill_status: "unbilled", locked: false } }
  let(:inputs) { { change: { action: :update }, role: "employee", acting_user_id: 1, edit_days: 7, today: } }

  [nil, :agent, "user_delegated", :"reservations.commit", "reservations.comit", false].each do |unknown|
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

  %w[
    reservations.prepare
    reservations.commit
    reservations.abort
    invoices.mark_billed
    entries.import
    agents.detach_entries
  ].each do |operation|
    it "accepts the background operation #{operation}" do
      expect(described_class.change_decision(caller: operation, entry:, **inputs)).to eq(:ok)
    end
  end

  it "accepts a user-delegated caller" do
    expect(described_class.change_decision(caller: :user_delegated, entry:, **inputs)).to eq(:ok)
  end

  it "keeps the background operation list frozen" do
    expect(TimekeepingRules::EntryRules::BACKGROUND_OPERATIONS).to be_frozen
    expect(TimekeepingRules::EntryRules::BACKGROUND_OPERATIONS).to all(be_frozen)
  end
end
