# frozen_string_literal: true

# == Schema Information
#
# Table name: invoice_line_items
#
#  id                 :bigint           not null, primary key
#  date               :date
#  description        :text
#  name               :string
#  quantity           :integer          default(1)
#  rate               :decimal(20, 2)   default(0.0)
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  invoice_id         :bigint           not null
#  timesheet_entry_id :bigint
#
# Indexes
#
#  index_invoice_line_items_on_invoice_id          (invoice_id)
#  index_invoice_line_items_on_timesheet_entry_id  (timesheet_entry_id)
#
# Foreign Keys
#
#  fk_rails_...  (invoice_id => invoices.id)
#
require "rails_helper"

RSpec.describe InvoiceLineItem, type: :model do
  subject { build(:invoice_line_item) }

  describe "Validations" do
    describe "validate presence of" do
      it { is_expected.to validate_presence_of(:name) }
      it { is_expected.to validate_presence_of(:date) }
      it { is_expected.to validate_presence_of(:rate) }
      it { is_expected.to validate_presence_of(:quantity) }
    end

    describe "validate numericality of" do
      it { is_expected.to validate_numericality_of(:quantity).is_greater_than_or_equal_to(0) }
      it { is_expected.to validate_numericality_of(:rate).is_greater_than_or_equal_to(0) }
    end

    describe "timesheet entry reference" do
      it "is invalid when timesheet_entry_id names no entry" do
        line_item = build(:invoice_line_item, timesheet_entry: nil)
        line_item.timesheet_entry_id = TimesheetEntry.maximum(:id).to_i + 1_000

        expect(line_item).not_to be_valid
        expect(line_item.errors[:timesheet_entry]).to include("must exist")
      end

      it "is valid with no timesheet entry, as a manual line" do
        line_item = build(:invoice_line_item, timesheet_entry: nil)

        expect(line_item).to be_valid
      end
    end
  end

  describe "company of the timesheet entries" do
    let(:invoice) { create(:invoice) }
    let(:other_company) { create(:company) }
    let(:other_company_entry) do
      project = create(:project, client: create(:client, company: other_company), billable: true)
      user = create(:user, current_workspace: other_company)
      create(:timesheet_entry, user:, project:, bill_status: "unbilled")
    end
    let(:same_company_entry) do
      project = create(:project, client: invoice.client, billable: true)
      user = create(:user, current_workspace: invoice.company)
      create(:timesheet_entry, user:, project:, bill_status: "unbilled")
    end

    it "is invalid when a linked timesheet entry belongs to another company" do
      line_item = build(:invoice_line_item, invoice:, timesheet_entry: nil)
      line_item.linked_timesheet_entries = [same_company_entry, other_company_entry]

      expect(line_item).not_to be_valid
      expect(line_item.errors[:linked_timesheet_entries]).to include("must belong to the same company")
    end

    it "is valid when every linked timesheet entry belongs to the invoice's company" do
      line_item = build(:invoice_line_item, invoice:, timesheet_entry: nil)
      line_item.linked_timesheet_entries = [same_company_entry]

      expect(line_item).to be_valid
    end

    it "is invalid when the direct timesheet entry belongs to another company" do
      line_item = build(:invoice_line_item, invoice:, timesheet_entry: other_company_entry)

      expect(line_item).not_to be_valid
      expect(line_item.errors[:timesheet_entry]).to include("must belong to the same company")
    end
  end

  describe "callbacks" do
    it { is_expected.to callback(:unlock_timesheet_entries).before(:destroy) }
  end

  describe "Associations" do
    describe "belongs to" do
      it { is_expected.to belong_to(:invoice) }
      it { is_expected.to belong_to(:timesheet_entry).optional(true) }
    end

    describe "has many" do
      it { is_expected.to have_many(:invoice_line_item_time_entries).dependent(:destroy) }
      it { is_expected.to have_many(:linked_timesheet_entries).through(:invoice_line_item_time_entries) }
    end
  end

  describe "Class Methods" do
    describe ".total_cost_of_all_line_items" do
      let(:invoice_line_item_1) { create :invoice_line_item }
      let(:invoice_line_item_2) { create :invoice_line_item }
      let(:invoice_line_item_3) { create :invoice_line_item }

      it "returns the number of hours multiplied by rate" do
        total_cost = invoice_line_item_1.total_cost + invoice_line_item_2.total_cost + invoice_line_item_3.total_cost

        expect(
          InvoiceLineItem.where(
            id: [
                          invoice_line_item_1.id,
                          invoice_line_item_2.id,
                          invoice_line_item_3.id
                        ]
                    ).total_cost_of_all_line_items
        ).to be_within(0.001).of(total_cost)
      end
    end
  end

  describe ".hours_spent" do
    let(:invoice_line_item) { create :invoice_line_item }

    it "returns the hours spent" do
      expect(invoice_line_item.hours_spent).to eq(invoice_line_item.quantity.to_f / 60)
      expect(invoice_line_item.hours_spent).to be_a_kind_of(Float)
    end
  end

  describe ".minutes_spent" do
    let(:invoice_line_item) { create :invoice_line_item }

    it "returns the hours spent" do
      expect(invoice_line_item.minutes_spent).to eq(invoice_line_item.quantity.to_f % 60)
      expect(invoice_line_item.minutes_spent).to be_a_kind_of(Float)
    end
  end

  describe ".time_spent" do
    let(:invoice_line_item) { create :invoice_line_item }

    describe "when quantity is 0" do
      it "returns 0" do
        invoice_line_item.quantity = 0
        expect(invoice_line_item.time_spent).to eq("00:00")
      end
    end

    describe "when hours is one digit" do
      it "returns a leading zero" do
        invoice_line_item.quantity = 90
        expect(invoice_line_item.time_spent).to eq("01:30")
      end
    end

    describe "when minutes is one digit" do
      it "returns a leading zero" do
        invoice_line_item.quantity = 61
        expect(invoice_line_item.time_spent).to eq("01:01")
      end
    end

    describe "when hours and minutes are two digits" do
      it "returns no leading zeros" do
        invoice_line_item.quantity = 630
        expect(invoice_line_item.time_spent).to eq("10:30")
      end
    end
  end

  describe ".total_cost" do
    let(:invoice_line_item) { create :invoice_line_item }

    it "returns the number of hours multiplied by rate" do
      expect(invoice_line_item.total_cost).to eq((invoice_line_item.hours_spent * invoice_line_item.rate).round(3))
    end
  end
end
