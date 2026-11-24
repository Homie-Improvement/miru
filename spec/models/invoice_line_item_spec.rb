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

        expect_entry_reference_refused(line_item, attribute: :timesheet_entry)
      end

      it "is invalid when timesheet_entry_id is 0, which names no entry" do
        line_item = build(:invoice_line_item, timesheet_entry: nil)
        line_item.timesheet_entry_id = 0

        expect_entry_reference_refused(line_item, attribute: :timesheet_entry)
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
    let(:null_company_entry) do
      project = create(:project, client: invoice.client, billable: true)
      user = create(:user, current_workspace: invoice.company)
      entry = create(:timesheet_entry, user:, project:, bill_status: "unbilled")
      # The save callback fills company_id from the project, so it is cleared without callbacks.
      entry.update_column(:company_id, nil)
      entry.reload
    end
    let(:missing_id) { TimesheetEntry.maximum(:id).to_i + 1_000 }

    it "is invalid when a linked timesheet entry belongs to another company" do
      line_item = build(:invoice_line_item, invoice:, timesheet_entry: nil)
      line_item.linked_timesheet_entries = [same_company_entry, other_company_entry]

      expect_entry_reference_refused(line_item, attribute: :linked_timesheet_entries)
    end

    it "is valid when every linked timesheet entry belongs to the invoice's company" do
      line_item = build(:invoice_line_item, invoice:, timesheet_entry: nil)
      line_item.linked_timesheet_entries = [same_company_entry]

      expect(line_item).to be_valid
    end

    it "is invalid when the direct timesheet entry belongs to another company" do
      line_item = build(:invoice_line_item, invoice:, timesheet_entry: other_company_entry)

      expect_entry_reference_refused(line_item, attribute: :timesheet_entry)
    end

    # Missing ids, other companies' ids and entries with no company must give
    # the same errors, so no response shows that an id exists elsewhere.
    it "gives the same errors for a foreign or NULL-company direct entry id as for a missing id" do
      missing_line = build(:invoice_line_item, invoice:, timesheet_entry: nil)
      missing_line.timesheet_entry_id = missing_id
      missing_refusal = expect_entry_reference_refused(missing_line, attribute: :timesheet_entry)

      [other_company_entry, null_company_entry].each do |entry|
        line = build(:invoice_line_item, invoice:, timesheet_entry: nil)
        line.timesheet_entry_id = entry.id

        expect(expect_entry_reference_refused(line, attribute: :timesheet_entry)).to eq(missing_refusal)

        loaded_line = build(:invoice_line_item, invoice:, timesheet_entry: entry)
        expect(expect_entry_reference_refused(loaded_line, attribute: :timesheet_entry)).to eq(missing_refusal)
      end
    end

    it "gives the same errors for foreign or NULL-company linked ids as for a missing id and links nothing" do
      missing_line = build(:invoice_line_item, invoice:, timesheet_entry: nil)
      missing_line.linked_timesheet_entry_ids = [same_company_entry.id, missing_id]
      missing_refusal = expect_entry_reference_refused(missing_line, attribute: :linked_timesheet_entries)

      [other_company_entry, null_company_entry].each do |entry|
        line = build(:invoice_line_item, invoice:, timesheet_entry: nil)
        line.linked_timesheet_entry_ids = [same_company_entry.id, entry.id]

        # Validation alone must refuse, so the save's own link check cannot hide a missing validation.
        expect(expect_entry_reference_refused(line, attribute: :linked_timesheet_entries)).to eq(missing_refusal)
        expect(expect_entry_reference_refused(line, attribute: :linked_timesheet_entries, via: :save))
          .to eq(missing_refusal)
        expect(line.linked_timesheet_entries).to be_empty
        expect(InvoiceLineItemTimeEntry.where(timesheet_entry_id: [same_company_entry.id, entry.id])).to be_empty
      end

      # The same company's entry alone does link, so the empty reads above can fail.
      own_line = build(:invoice_line_item, invoice:, timesheet_entry: nil)
      own_line.linked_timesheet_entry_ids = [same_company_entry.id]
      own_line.save!
      expect(own_line.reload.linked_timesheet_entries).to eq([same_company_entry])
    end

    it "refuses an entry whose project is in the invoice's company but whose stored company_id is another company or NULL" do
      # same_company_entry's project is in the invoice's company, so only a check
      # on the stored column refuses these rows.
      mislabelled_entry = same_company_entry
      mislabelled_entry.update_column(:company_id, other_company.id)

      [mislabelled_entry.reload, null_company_entry].each do |entry|
        direct_line = build(:invoice_line_item, invoice:, timesheet_entry: entry)
        expect_entry_reference_refused(direct_line, attribute: :timesheet_entry)

        linked_line = build(:invoice_line_item, invoice:, timesheet_entry: nil)
        linked_line.linked_timesheet_entries = [entry]
        expect_entry_reference_refused(linked_line, attribute: :linked_timesheet_entries)
      end
    end

    it "gives the same not found for linked ids assigned before the invoice is set, whether foreign or nonexistent" do
      # Nested attributes assign the ids before the line knows its invoice, so the lookup must wait for validation.
      errors_for = lambda do |entry_id|
        line = InvoiceLineItem.new(name: "Linked", date: Date.current, rate: 10, quantity: 60)
        line.linked_timesheet_entry_ids = [entry_id]
        line.invoice = invoice
        expect_entry_reference_refused(line, attribute: :linked_timesheet_entries)
      end

      expect(errors_for.call(other_company_entry.id)).to eq(errors_for.call(missing_id))
    end

    it "counts a persisted line with only pending linked ids as changed for autosave" do
      line = InvoiceLineItem.find(create(:invoice_line_item, invoice:, timesheet_entry: nil).id)
      expect(line.changed_for_autosave?).to be(false)

      line.linked_timesheet_entry_ids = [same_company_entry.id]

      # Nested invoice saves validate only children that report a change, so pending ids must count as one.
      expect(line.changed_for_autosave?).to be(true)
    end

    it "marks an existing line changed when only foreign or nonexistent linked ids are assigned, so the invoice save refuses them" do
      persisted_line = create(:invoice_line_item, invoice:, timesheet_entry: nil)

      # Only the linked ids change, so no column is dirty; autosave must still pick the line up.
      refusals = [other_company_entry.id, missing_id].map do |entry_id|
        reloaded_invoice = Invoice.find(invoice.id)
        line = reloaded_invoice.invoice_line_items.find { |item| item.id == persisted_line.id }
        expect { line.linked_timesheet_entry_ids = [entry_id] }.not_to raise_error

        expect(line.changed_for_autosave?).to be(true)
        expect_entry_reference_refused(reloaded_invoice, attribute: :"invoice_line_items.linked_timesheet_entries",
                                                         via: :save)
      end

      expect(refusals.first).to eq(refusals.last)
      expect(InvoiceLineItemTimeEntry.where(invoice_line_item_id: persisted_line.id)).to be_empty
    end

    it "writes pending linked ids of a saved line only on save, never on validation" do
      line = InvoiceLineItem.find(create(:invoice_line_item, invoice:, timesheet_entry: nil).id)
      line.linked_timesheet_entry_ids = [same_company_entry.id]

      expect(line).to be_valid
      expect(InvoiceLineItemTimeEntry.where(invoice_line_item_id: line.id)).to be_empty

      line.save!
      expect(InvoiceLineItemTimeEntry.where(invoice_line_item_id: line.id).pluck(:timesheet_entry_id))
        .to eq([same_company_entry.id])
    end

    it "reads zero-padded linked ids as decimal, the way the id column casts them" do
      line = create(:invoice_line_item, invoice:, timesheet_entry: nil)

      line.linked_timesheet_entry_ids = ["0#{same_company_entry.id}"]
      line.save!

      expect(line.reload.linked_timesheet_entries).to eq([same_company_entry])
    end

    it "clears and replaces links even when a current link no longer belongs to the invoice's company" do
      stale_entry = same_company_entry
      replacement = create(
        :timesheet_entry,
        user: stale_entry.user,
        project: stale_entry.project,
        bill_status: "unbilled"
      )
      line = create(:invoice_line_item, invoice:, timesheet_entry: nil)
      create(:invoice_line_item_time_entry, invoice_line_item: line, timesheet_entry: stale_entry)
      stale_entry.update_column(:company_id, nil)

      line = InvoiceLineItem.find(line.id)
      line.linked_timesheet_entry_ids = [replacement.id]
      expect(line.save).to be(true)
      expect(line.reload.linked_timesheet_entries).to eq([replacement])

      line.linked_timesheet_entry_ids = []
      expect(line.save).to be(true)
      expect(InvoiceLineItemTimeEntry.where(invoice_line_item_id: line.id)).to be_empty
    end

    it "refuses the save when a pending linked entry stops resolving after validation" do
      line = create(:invoice_line_item, invoice:, timesheet_entry: nil)
      line.linked_timesheet_entry_ids = [same_company_entry.id]
      expect(line).to be_valid

      # Stands for another transaction moving the entry out of the company between validation and save.
      same_company_entry.update_column(:company_id, nil)

      expect_entry_reference_refused(line, attribute: :linked_timesheet_entries, via: :save_without_validation)
      expect(InvoiceLineItemTimeEntry.where(invoice_line_item_id: line.id)).to be_empty
    end
  end

  describe "callbacks" do
    it { is_expected.to callback(:register_reservation_change).before(:destroy) }
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

  context "more tests 2", type: :model do
    # "The legacy and rollback states keep today's invoice validation behaviour, and the 12.1 invoice specs still pass in all three states"
    it "a line naming no entry or another company's entry is refused through the current owner's own check in every ownership state" do
      invoice = create(:invoice)
      other_company = create(:company)
      foreign_project = create(:project, client: create(:client, company: other_company), billable: true)
      foreign_user = create(:user, current_workspace: other_company)
      foreign_entry = create(:timesheet_entry, user: foreign_user, project: foreign_project, bill_status: "unbilled")
      missing_id = TimesheetEntry.maximum(:id).to_i + 1_000

      [missing_id, foreign_entry.id].each do |entry_id|
        line = build(:invoice_line_item, invoice:, timesheet_entry: nil)
        line.timesheet_entry_id = entry_id

        expect_entry_reference_refused(line, attribute: :timesheet_entry)
        expect(InvoiceLineItem.where(invoice_id: invoice.id, timesheet_entry_id: entry_id)).to be_empty
      end
    end
  end
end
