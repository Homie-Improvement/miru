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
        expect(line_item.errors[:timesheet_entry]).to include("not found")
      end

      it "is invalid when timesheet_entry_id is 0, which names no entry" do
        line_item = build(:invoice_line_item, timesheet_entry: nil)
        line_item.timesheet_entry_id = 0

        expect(line_item).not_to be_valid
        expect(line_item.errors[:timesheet_entry]).to include("not found")
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
      expect(line_item.errors[:linked_timesheet_entries]).to include("not found")
    end

    it "is valid when every linked timesheet entry belongs to the invoice's company" do
      line_item = build(:invoice_line_item, invoice:, timesheet_entry: nil)
      line_item.linked_timesheet_entries = [same_company_entry]

      expect(line_item).to be_valid
    end

    it "is invalid when the direct timesheet entry belongs to another company" do
      line_item = build(:invoice_line_item, invoice:, timesheet_entry: other_company_entry)

      expect(line_item).not_to be_valid
      expect(line_item.errors[:timesheet_entry]).to include("not found")
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

# Generated by Descant: acceptance tests below.
RSpec.describe InvoiceLineItem, "entry ids from another company", type: :model do
  it "reports not found for a foreign direct entry and for foreign linked entry ids" do
    invoice = create(:invoice)
    other_company = create(:company)
    other_project = create(:project, client: create(:client, company: other_company), billable: true)
    other_user = create(:user, current_workspace: other_company)
    foreign_entry = create(:timesheet_entry, user: other_user, project: other_project, bill_status: "unbilled")

    direct_line = build(:invoice_line_item, invoice:, timesheet_entry: nil)
    direct_line.timesheet_entry_id = foreign_entry.id

    linked_line = build(:invoice_line_item, invoice:, timesheet_entry: nil)
    linked_line.linked_timesheet_entry_ids = [foreign_entry.id]

    # "An id from another company gives not_found."
    expect(direct_line).not_to be_valid
    expect(direct_line.errors[:timesheet_entry]).to eq(["not found"])
    expect(linked_line).not_to be_valid
    expect(linked_line.errors[:linked_timesheet_entries]).to eq(["not found"])
    expect(linked_line.linked_timesheet_entries).to be_empty
  end
end

RSpec.describe InvoiceLineItem, "entry with a NULL company_id", type: :model do
  it "reports not found for an entry in the invoice's company project whose company_id is NULL" do
    invoice = create(:invoice)
    project = create(:project, client: invoice.client, billable: true)
    user = create(:user, current_workspace: invoice.company)
    null_company_entry = create(:timesheet_entry, user:, project:, bill_status: "unbilled")
    # The save callback fills company_id from the project, so it is cleared without callbacks.
    null_company_entry.update_column(:company_id, nil)

    direct_line = build(:invoice_line_item, invoice:, timesheet_entry: nil)
    direct_line.timesheet_entry_id = null_company_entry.id

    linked_line = build(:invoice_line_item, invoice:, timesheet_entry: nil)
    linked_line.linked_timesheet_entry_ids = [null_company_entry.id]

    # "A row whose `company_id` is NULL is not_found, never accepted for every company."
    expect(direct_line).not_to be_valid
    expect(direct_line.errors[:timesheet_entry]).to eq(["not found"])
    expect(linked_line).not_to be_valid
    expect(linked_line.errors[:linked_timesheet_entries]).to eq(["not found"])
  end
end

RSpec.describe InvoiceLineItem, type: :model do
  it "reports another company's direct and linked entry ids as not found, the same as an id that names no entry" do
    invoice = create(:invoice)
    other_company = create(:company)
    other_project = create(:project, client: create(:client, company: other_company), billable: true)
    other_user = create(:user, current_workspace: other_company)
    foreign_entry = create(:timesheet_entry, user: other_user, project: other_project, bill_status: "unbilled")
    missing_id = TimesheetEntry.maximum(:id).to_i + 1_000

    # "A missing id and a foreign id must both give the same `not_found` error, rendered through the existing 422 path."
    foreign_direct = build(:invoice_line_item, invoice:, timesheet_entry: nil)
    foreign_direct.timesheet_entry_id = foreign_entry.id
    missing_direct = build(:invoice_line_item, invoice:, timesheet_entry: nil)
    missing_direct.timesheet_entry_id = missing_id

    expect(foreign_direct).not_to be_valid
    expect(missing_direct).not_to be_valid
    expect(foreign_direct.errors[:timesheet_entry]).to include("not found")
    expect(foreign_direct.errors.full_messages).to eq(missing_direct.errors.full_messages)

    foreign_linked = build(:invoice_line_item, invoice:, timesheet_entry: nil)
    foreign_linked.linked_timesheet_entry_ids = [foreign_entry.id]
    missing_linked = build(:invoice_line_item, invoice:, timesheet_entry: nil)
    missing_linked.linked_timesheet_entry_ids = [missing_id]

    expect(foreign_linked).not_to be_valid
    expect(missing_linked).not_to be_valid
    expect(foreign_linked.errors[:linked_timesheet_entries]).to include("not found")
    expect(foreign_linked.errors.full_messages).to eq(missing_linked.errors.full_messages)
    expect(foreign_linked.linked_timesheet_entries).not_to include(foreign_entry)
  end
end

RSpec.describe InvoiceLineItem, type: :model do
  it "reports an entry in the invoice company's project whose stored company_id is NULL as not found, directly and linked" do
    invoice = create(:invoice)
    project = create(:project, client: invoice.client, billable: true)
    user = create(:user, current_workspace: invoice.company)
    null_company_entry = create(:timesheet_entry, user:, project:, bill_status: "unbilled")
    # update_column skips the before_save that would fill company_id from the project again.
    null_company_entry.update_column(:company_id, nil)

    # "A row whose `company_id` is NULL is not_found, never accepted for every company."
    direct = build(:invoice_line_item, invoice:, timesheet_entry: nil)
    direct.timesheet_entry_id = null_company_entry.id
    expect(direct).not_to be_valid
    expect(direct.errors[:timesheet_entry]).to include("not found")

    linked = build(:invoice_line_item, invoice:, timesheet_entry: nil)
    linked.linked_timesheet_entry_ids = [null_company_entry.id]
    expect(linked).not_to be_valid
    expect(linked.errors[:linked_timesheet_entries]).to include("not found")
  end
end

RSpec.describe InvoiceLineItem do
  it "reports a NULL-company direct entry with the same not found errors as a missing id" do
    invoice = create(:invoice)
    project = create(:project, client: invoice.client, billable: true)
    user = create(:user, current_workspace: invoice.company)
    null_company_entry = create(:timesheet_entry, user:, project:, bill_status: "unbilled")
    null_company_entry.update_column(:company_id, nil)

    null_line = build(:invoice_line_item, invoice:, timesheet_entry: nil)
    null_line.timesheet_entry_id = null_company_entry.id
    missing_line = build(:invoice_line_item, invoice:, timesheet_entry: nil)
    missing_line.timesheet_entry_id = TimesheetEntry.maximum(:id).to_i + 1_000

    # "A row whose `company_id` is NULL is not_found, never accepted for every company."
    expect(null_line).not_to be_valid
    expect(missing_line).not_to be_valid
    expect(null_line.errors[:timesheet_entry]).to eq(["not found"])
    expect(null_line.errors.full_messages).to eq(missing_line.errors.full_messages)
  end
end

RSpec.describe InvoiceLineItem do
  it "reports foreign and missing linked ids with the same not found errors and links only company entries" do
    invoice = create(:invoice)
    own_project = create(:project, client: invoice.client, billable: true)
    own_user = create(:user, current_workspace: invoice.company)
    own_entry = create(:timesheet_entry, user: own_user, project: own_project, bill_status: "unbilled")
    other_company = create(:company)
    other_project = create(:project, client: create(:client, company: other_company), billable: true)
    other_user = create(:user, current_workspace: other_company)
    foreign_entry = create(:timesheet_entry, user: other_user, project: other_project, bill_status: "unbilled")

    foreign_line = build(:invoice_line_item, invoice:, timesheet_entry: nil)
    foreign_line.linked_timesheet_entry_ids = [own_entry.id, foreign_entry.id]
    missing_line = build(:invoice_line_item, invoice:, timesheet_entry: nil)
    missing_line.linked_timesheet_entry_ids = [own_entry.id, TimesheetEntry.maximum(:id).to_i + 1_000]
    own_line = build(:invoice_line_item, invoice:, timesheet_entry: nil)
    own_line.linked_timesheet_entry_ids = [own_entry.id]

    # "A missing id and a foreign id must both give the same `not_found` error"
    expect(foreign_line).not_to be_valid
    expect(missing_line).not_to be_valid
    expect(foreign_line.errors[:linked_timesheet_entries]).to eq(["not found"])
    expect(foreign_line.errors.full_messages).to eq(missing_line.errors.full_messages)
    expect(foreign_line.linked_timesheet_entries.map(&:id)).not_to include(foreign_entry.id)

    expect(own_line).to be_valid
    expect(own_line.linked_timesheet_entries.map(&:id)).to eq([own_entry.id])
  end
end

RSpec.describe InvoiceLineItem do
  it "counts a persisted line with only pending linked ids as changed for autosave" do
    invoice = create(:invoice)
    project = create(:project, client: invoice.client, billable: true)
    user = create(:user, current_workspace: invoice.company)
    entry = create(:timesheet_entry, user:, project:, bill_status: "unbilled")
    line = InvoiceLineItem.find(create(:invoice_line_item, invoice:, timesheet_entry: nil).id)
    expect(line.changed_for_autosave?).to be(false)

    line.linked_timesheet_entry_ids = [entry.id]

    # Nested invoice saves validate only children that report a change, so pending ids must count as one.
    expect(line.changed_for_autosave?).to be(true)
  end
end

RSpec.describe InvoiceLineItem do
  it "reports another company's direct entry with the same not found errors as a missing id" do
    invoice = create(:invoice)
    other_company = create(:company)
    other_project = create(:project, client: create(:client, company: other_company), billable: true)
    other_user = create(:user, current_workspace: other_company)
    # A real entry in a second company that sits on no invoice.
    foreign_entry = create(:timesheet_entry, user: other_user, project: other_project, bill_status: "unbilled")

    foreign_line = build(:invoice_line_item, invoice:, timesheet_entry: nil)
    foreign_line.timesheet_entry_id = foreign_entry.id
    missing_line = build(:invoice_line_item, invoice:, timesheet_entry: nil)
    missing_line.timesheet_entry_id = TimesheetEntry.maximum(:id).to_i + 1_000

    expect(foreign_line).not_to be_valid
    expect(missing_line).not_to be_valid
    # "A missing id and a foreign id must both give the same `not_found` error, rendered through the existing 422 path."
    expect(foreign_line.errors[:timesheet_entry]).to eq(["not found"])
    expect(foreign_line.errors.full_messages).to eq(missing_line.errors.full_messages)
  end
end

RSpec.describe InvoiceLineItem, type: :model do
  it "marks an existing line changed when only foreign or nonexistent linked ids are assigned, so the invoice save refuses them" do
    invoice = create(:invoice)
    persisted_line = create(:invoice_line_item, invoice:, timesheet_entry: nil)
    other_company = create(:company)
    other_project = create(:project, client: create(:client, company: other_company), billable: true)
    other_user = create(:user, current_workspace: other_company)
    foreign_entry = create(:timesheet_entry, user: other_user, project: other_project, bill_status: "unbilled")
    nonexistent_id = TimesheetEntry.maximum(:id).to_i + 1_000

    # "Resolve `timesheet_entry_id` and linked entry ids only within `invoice.company_id` (`timesheet_entries.company_id`, kept equal to the project's company by `assign_company_from_project` and the backfill)."
    # Only the linked ids change, so no column is dirty; autosave must still pick the line up.
    messages = [foreign_entry.id, nonexistent_id].map do |entry_id|
      reloaded_invoice = Invoice.find(invoice.id)
      line = reloaded_invoice.invoice_line_items.find { |item| item.id == persisted_line.id }
      expect { line.linked_timesheet_entry_ids = [entry_id] }.not_to raise_error

      expect(line.changed_for_autosave?).to be(true)
      expect(reloaded_invoice.save).to be(false)
      reloaded_invoice.errors.full_messages.first
    end

    expect(messages.first).to include("not found")
    expect(messages.first).to eq(messages.last)
    expect(InvoiceLineItemTimeEntry.where(invoice_line_item_id: persisted_line.id)).to be_empty
  end
end

RSpec.describe InvoiceLineItem, type: :model do
  it "gives the same not found for linked ids assigned before the invoice is set, whether foreign or nonexistent" do
    invoice = create(:invoice)
    other_company = create(:company)
    other_project = create(:project, client: create(:client, company: other_company), billable: true)
    other_user = create(:user, current_workspace: other_company)
    foreign_entry = create(:timesheet_entry, user: other_user, project: other_project, bill_status: "unbilled")
    nonexistent_id = TimesheetEntry.maximum(:id).to_i + 1_000

    # "A missing id and a foreign id must both give the same `not_found` error, rendered through the existing 422 path."
    # Nested attributes assign the ids before the line knows its invoice, so the lookup must wait for validation.
    errors_for = lambda do |entry_id|
      line = InvoiceLineItem.new(name: "Linked", date: Date.current, rate: 10, quantity: 60)
      line.linked_timesheet_entry_ids = [entry_id]
      line.invoice = invoice
      expect(line).not_to be_valid
      line.errors.to_hash
    end

    foreign_errors = errors_for.call(foreign_entry.id)
    expect(foreign_errors[:linked_timesheet_entries]).to include("not found")
    expect(foreign_errors).to eq(errors_for.call(nonexistent_id))
  end
end

RSpec.describe InvoiceLineItem, type: :model do
  it "refuses an entry whose project is in the invoice's company but whose stored company_id is another company or NULL" do
    invoice = create(:invoice)
    project = create(:project, client: invoice.client, billable: true)
    user = create(:user, current_workspace: invoice.company)
    other_company = create(:company)
    mislabelled_entry = create(:timesheet_entry, user:, project:, bill_status: "unbilled")
    mislabelled_entry.update_column(:company_id, other_company.id)
    null_company_entry = create(:timesheet_entry, user:, project:, bill_status: "unbilled")
    null_company_entry.update_column(:company_id, nil)

    # "Resolve `timesheet_entry_id` and linked entry ids only within `invoice.company_id` (`timesheet_entries.company_id`, kept equal to the project's company by `assign_company_from_project` and the backfill)."
    # "A row whose `company_id` is NULL is not_found, never accepted for every company."
    # The project's company matches here, so only a check on the stored column refuses these rows.
    [mislabelled_entry, null_company_entry].each do |entry|
      direct_line = build(:invoice_line_item, invoice:, timesheet_entry: entry.reload)
      expect(direct_line).not_to be_valid
      expect(direct_line.errors[:timesheet_entry]).to include("not found")

      linked_line = build(:invoice_line_item, invoice:, timesheet_entry: nil)
      linked_line.linked_timesheet_entries = [entry]
      expect(linked_line).not_to be_valid
      expect(linked_line.errors[:linked_timesheet_entries]).to include("not found")
    end
  end
end

RSpec.describe InvoiceLineItem, type: :model do
  it "gives identical errors for a direct foreign entry loaded into the association and a direct id that names no entry" do
    invoice = create(:invoice)
    other_company = create(:company)
    other_project = create(:project, client: create(:client, company: other_company), billable: true)
    other_user = create(:user, current_workspace: other_company)
    foreign_entry = create(:timesheet_entry, user: other_user, project: other_project, bill_status: "unbilled")

    # "A missing id and a foreign id must both give the same `not_found` error, rendered through the existing 422 path."
    foreign_line = build(:invoice_line_item, invoice:, timesheet_entry: foreign_entry)
    missing_line = build(:invoice_line_item, invoice:, timesheet_entry: nil)
    missing_line.timesheet_entry_id = TimesheetEntry.maximum(:id).to_i + 1_000

    expect(foreign_line).not_to be_valid
    expect(missing_line).not_to be_valid
    expect(foreign_line.errors[:timesheet_entry]).to eq(["not found"])
    expect(foreign_line.errors.to_hash).to eq(missing_line.errors.to_hash)
  end
end
