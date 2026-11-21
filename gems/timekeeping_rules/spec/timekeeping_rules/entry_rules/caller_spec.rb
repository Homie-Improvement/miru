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

  it "lists exactly the five live background operations, frozen and without entries.import" do
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
  end
end
