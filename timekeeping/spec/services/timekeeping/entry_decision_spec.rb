# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::EntryDecision do
  let(:today) { Date.new(2026, 3, 3) }
  let(:company_user_ids) { [7, 8, 12] }

  def entry(id:, user_id: 7, work_date: today, bill_status: "unbilled", locked: false)
    { id:, user_id:, work_date:, bill_status:, locked: }
  end

  def target(role:, requested_user_id:, acting_user_id: 7)
    described_class.target_user(acting_user_id:, role:, requested_user_id:, company_user_ids:)
  end

  describe ".target_user" do
    it "reads an employee's own id sent as a string as the acting user" do
      expect(target(role: "employee", requested_user_id: "7")).to eq(:acting)
    end

    it "lets an owner name a same-company user whose id is sent as a string" do
      expect(target(role: "owner", requested_user_id: "12")).to eq(:requested)
    end

    it "lets an admin name a same-company user by integer id" do
      expect(target(role: "admin", requested_user_id: 12)).to eq(:requested)
    end

    it "takes the acting user when user_id is missing" do
      expect(target(role: "employee", requested_user_id: nil)).to eq(:acting)
    end

    it "refuses an employee who names a colleague" do
      expect(target(role: "employee", requested_user_id: 8)).to eq(:forbidden)
    end

    it "answers an owner who names a user outside the company as not_found" do
      expect(target(role: "owner", requested_user_id: 99)).to eq(:not_found)
    end

    it "answers a user_id that is not an id as a missing user" do
      ["7abc", "", 7.0, ["7"], { "id" => 7 }].each do |value|
        expect(target(role: "owner", requested_user_id: value)).to eq(:not_found)
        expect(target(role: "employee", requested_user_id: value)).to eq(:forbidden)
      end
    end
  end

  describe ".version" do
    it "accepts a matching If-Match" do
      expect(described_class.version(if_match: "3", current_version: 3)).to eq(:ok)
    end

    it "answers a stale If-Match as version_conflict" do
      expect(described_class.version(if_match: "2", current_version: 3)).to eq(:version_conflict)
    end

    it "answers an If-Match that is not a plain integer as version_conflict" do
      ["3abc", "", "\"3\""].each do |if_match|
        expect(described_class.version(if_match:, current_version: 3)).to eq(:version_conflict)
      end
    end

    it "leaves the version unchecked without If-Match" do
      expect(described_class.version(if_match: nil, current_version: 3)).to eq(:ok)
    end
  end

  describe ".change" do
    def change(role:, entry:, action: :update, bill_status: nil)
      described_class.change(action:, bill_status:, role:, acting_user_id: 7, entry:, edit_days: 30, today:)
    end

    it "allows an employee to update their own free entry" do
      expect(change(role: "employee", entry: entry(id: 1))).to eq(:ok)
    end

    it "refuses an employee's update of a reserved entry" do
      expect(change(role: "employee", entry: entry(id: 1, locked: true))).to eq(:forbidden)
    end

    it "refuses any change to a billed entry" do
      expect(change(role: "owner", entry: entry(id: 1, bill_status: "billed"), action: :delete)).to eq(:forbidden)
    end
  end

  describe ".bulk" do
    def bulk(role:, entries:, action: :move)
      described_class.bulk(action:, role:, acting_user_id: 7, entries:, edit_days: 30, today:)
    end

    it "skips a reserved entry in an employee's bulk move and applies the free one" do
      entries = [entry(id: 1, locked: true), entry(id: 2)]

      expect(bulk(role: "employee", entries:)).to eq(1 => :skip, 2 => :apply)
    end

    it "refuses the whole request when one entry is billed" do
      entries = [entry(id: 1), entry(id: 2, bill_status: "billed")]

      expect(bulk(role: "owner", entries:)).to eq(:forbidden)
    end

    it "refuses an employee's whole request when one entry is outside the edit window" do
      entries = [entry(id: 1), entry(id: 2, work_date: today - 31)]

      expect(bulk(role: "employee", entries:)).to eq(:forbidden)
    end

    it "applies an employee's bulk delete of a reserved entry" do
      expect(bulk(role: "employee", entries: [entry(id: 1, locked: true)], action: :delete)).to eq(1 => :apply)
    end
  end
end
