# frozen_string_literal: true

require "date"

RSpec.describe TimekeepingRules::EntryRules, ".change_decision and .refusing_rules" do
  let(:today) { Date.new(2026, 3, 10) }
  let(:edit_days) { 7 }

  def entry(**overrides)
    { id: 1, user_id: 1, work_date: today, bill_status: "unbilled", locked: false }.merge(overrides)
  end

  def update(bill_status: nil)
    { action: :update, bill_status: }
  end

  def delete
    { action: :delete }
  end

  def inputs(entry:, caller: :user_delegated, change: update, role: "employee", primary_role: role, acting_user_id: 1)
    { caller:, change:, role:, primary_role:, acting_user_id:, entry:, edit_days:, today: }
  end

  def decide(**)
    described_class.change_decision(**inputs(**))
  end

  def rules(**)
    described_class.refusing_rules(**inputs(**))
  end

  describe "A6 locked entries and the A8 background skip" do
    it "refuses a user-delegated employee updating their own locked entry" do
      expect(rules(entry: entry(locked: true))).to eq([:a6])
      expect(decide(entry: entry(locked: true))).to eq(:forbidden)
    end

    it "allows an admin to update a locked entry" do
      expect(decide(entry: entry(locked: true), role: "admin")).to eq(:ok)
    end

    it "allows a named background operation to update a locked entry" do
      expect(decide(entry: entry(locked: true), caller: "reservations.commit", role: nil, acting_user_id: nil)).to eq(:ok)
    end

    it "does not bind a non-employee, non-privileged role" do
      expect(rules(entry: entry(locked: true), role: "book_keeper")).not_to include(:a6)
    end
  end

  describe "A7 changes away from billed" do
    let(:billed_entry) { entry(bill_status: "billed") }

    it "refuses a user-delegated employee moving an entry away from billed" do
      expect(rules(entry: billed_entry, change: update(bill_status: "unbilled"))).to eq(%i[a2 a7])
    end

    it "does not bind an admin, whom only A2 refuses" do
      expect(rules(entry: billed_entry, change: update(bill_status: "unbilled"), role: "admin")).to eq([:a2])
    end

    it "does not bind a named background operation, whom only A2 refuses" do
      result = rules(entry: billed_entry, change: update(bill_status: "unbilled"),
        caller: "invoices.mark_billed", role: nil, acting_user_id: nil)
      expect(result).to eq([:a2])
    end

    it "does not bind a non-employee, non-privileged role" do
      expect(rules(entry: billed_entry, change: update(bill_status: "unbilled"), role: "book_keeper")).not_to include(:a7)
    end

    it "does not bind an update that leaves bill_status alone" do
      expect(rules(entry: billed_entry)).to eq([:a2])
    end
  end

  describe "A2 billed entries" do
    it "refuses an admin updating or deleting a billed entry" do
      expect(decide(entry: entry(bill_status: "billed"), role: "admin")).to eq(:forbidden)
      expect(decide(entry: entry(bill_status: "billed"), role: "admin", change: delete)).to eq(:forbidden)
    end

    it "allows an admin to delete an unbilled entry" do
      expect(decide(entry: entry, role: "admin", change: delete)).to eq(:ok)
    end

    it "refuses a background operation updating or deleting a billed entry" do
      background = { caller: "agents.detach_entries", role: nil, acting_user_id: nil }
      expect(decide(entry: entry(bill_status: "billed"), **background)).to eq(:forbidden)
      expect(decide(entry: entry(bill_status: "billed"), change: delete, **background)).to eq(:forbidden)
    end
  end

  describe "background callers skip the user rules" do
    it "allows a background operation on a locked, stale, foreign, unbilled entry" do
      foreign = entry(user_id: 2, locked: true, work_date: today - 30)
      expect(decide(entry: foreign, caller: "entries.import", role: nil, acting_user_id: nil)).to eq(:ok)
    end
  end

  describe "A3 edit window" do
    it "allows an employee on the boundary day" do
      expect(decide(entry: entry(work_date: today - edit_days))).to eq(:ok)
    end

    it "refuses an employee one day past the window" do
      expect(rules(entry: entry(work_date: today - edit_days - 1))).to eq([:a3])
    end

    it "never treats an entry without a work date as stale" do
      expect(decide(entry: entry(work_date: nil))).to eq(:ok)
    end

    it "allows an owner or admin to change a stale entry" do
      expect(decide(entry: entry(work_date: today - 30), role: "owner")).to eq(:ok)
      expect(decide(entry: entry(work_date: today - 30), role: "admin")).to eq(:ok)
    end

    it "binds a non-employee, non-privileged role" do
      expect(rules(entry: entry(work_date: today - 30), role: "book_keeper")).to eq([:a3])
    end
  end

  describe "A4 own entries" do
    it "refuses an employee changing a colleague's entry" do
      expect(rules(entry: entry(user_id: 2))).to eq([:a4])
    end

    it "allows an employee to change their own entry" do
      expect(decide(entry: entry)).to eq(:ok)
    end

    it "allows an admin to change a colleague's entry" do
      expect(decide(entry: entry(user_id: 2), role: "admin")).to eq(:ok)
    end
  end

  describe "A10 deletes skip A6" do
    it "allows an employee to delete their own locked entry" do
      expect(decide(entry: entry(locked: true), change: delete)).to eq(:ok)
    end

    it "still refuses an employee deleting a colleague's locked entry" do
      expect(rules(entry: entry(user_id: 2, locked: true), change: delete)).to eq([:a4])
    end
  end

  describe "A11 setting billed" do
    it "allows an employee to mark their own fresh entry billed" do
      expect(decide(entry: entry, change: update(bill_status: "billed"))).to eq(:ok)
    end

    it "refuses an employee marking a colleague's entry billed" do
      expect(decide(entry: entry(user_id: 2), change: update(bill_status: "billed"))).to eq(:forbidden)
    end
  end

  describe "input checks" do
    it "raises on an unknown change action" do
      expect { decide(entry: entry, change: { action: :archive }) }.to raise_error(ArgumentError)
      expect { rules(entry: entry, change: { action: :archive }) }.to raise_error(ArgumentError)
    end

    it "raises on a bulk-only action" do
      expect { decide(entry: entry, change: { action: :move }) }.to raise_error(ArgumentError)
    end

    it "raises when a user-delegated role is not a String" do
      expect { decide(entry: entry, role: :employee) }.to raise_error(ArgumentError)
    end

    it "does not mutate its arguments" do
      frozen_entry = entry(locked: true).freeze
      frozen_change = update(bill_status: "billed").freeze
      expect(decide(entry: frozen_entry, change: frozen_change)).to eq(:forbidden)
    end
  end

  it "keeps the change rule table and each of its rows frozen" do
    expect(TimekeepingRules::EntryRules::CHANGE_RULES).to be_frozen
    expect(TimekeepingRules::EntryRules::CHANGE_RULES).to all(be_frozen)
  end
end

# Generated by Descant: acceptance tests below.
RSpec.describe TimekeepingRules::EntryRules, ".change_decision with a raised role" do
  # "This gives no one more write authority than the monolith already grants through `has_role?`."
  # The monolith refuses this user's locked edit through primary_role == "employee", so A6 must too.
  it "refuses a locked colleague update for an admin token whose primary role is employee and refuses a call without primary_role" do
    today = Date.new(2026, 3, 10)
    locked_colleague_entry = { id: 1, user_id: 2, work_date: today, bill_status: "unbilled", locked: true }
    inputs = {
      caller: :user_delegated, change: { action: :update, bill_status: nil }, role: "admin",
      acting_user_id: 1, entry: locked_colleague_entry, edit_days: 7, today:
    }

    expect(described_class.change_decision(**inputs, primary_role: "employee")).to eq(:forbidden)
    expect(described_class.change_decision(**inputs, entry: locked_colleague_entry.merge(locked: false),
                                                     primary_role: "employee")).to eq(:ok)
    expect(described_class.refusing_rules(**inputs, primary_role: "employee")).to eq([:a6])
    expect(described_class.change_decision(**inputs, primary_role: "admin")).to eq(:ok)
    expect(described_class.change_decision(**inputs, change: { action: :delete }, primary_role: "employee")).to eq(:ok)
    expect { described_class.change_decision(**inputs) }.to raise_error(ArgumentError)
  end
end
