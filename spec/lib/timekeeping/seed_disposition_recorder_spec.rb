# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::SeedDispositionRecorder do
  let(:company) { create(:company, name: "Recorder Co") }
  let(:client) { create(:client, company:) }
  let(:project) { create(:project, client:, billable: true) }
  let(:entry_owner) { create(:user, current_workspace_id: company.id) }

  def recorder_spec_entry(locked: false)
    entry = create(:timesheet_entry, user: entry_owner, project:, bill_status: "unbilled")
    entry.update_columns(locked:)
    entry
  end

  def recorder_spec_aggregate_line(invoice, linked_entries)
    line = create(:invoice_line_item, invoice:, timesheet_entry: nil, rate: 100, quantity: 120)
    linked_entries.each do |entry|
      create(:invoice_line_item_time_entry, invoice_line_item: line, timesheet_entry: entry)
    end
    line
  end

  def recorder_spec_sent_invoice(number)
    create(:invoice, company:, client:, invoice_number: number, status: :sent)
  end

  describe ".load_fresh_seed!" do
    it "refuses a database holding only a user with no company, and leaves that user unchanged" do
      user = create(:user, email: "dana@forkandleaf.example", current_workspace: nil, first_name: "Existing")
      Company.delete_all
      before = user.reload.attributes.slice("first_name", "last_name", "encrypted_password", "current_workspace_id")

      expect { described_class.load_fresh_seed!(as_of: "2026-10-23") }
        .to raise_error(described_class::Error, /users/)

      expect(user.reload.attributes.slice("first_name", "last_name", "encrypted_password", "current_workspace_id"))
        .to eq(before)
      expect(Company.count).to eq(0)
    end

    it "refuses a database holding a company and leaves its entries' lock state unchanged" do
      locked_entry = recorder_spec_entry(locked: true)
      unlocked_entry = recorder_spec_entry(locked: false)

      expect { described_class.load_fresh_seed!(as_of: "2026-10-23") }
        .to raise_error(described_class::Error, /companies/)

      expect(locked_entry.reload.locked).to be(true)
      expect(unlocked_entry.reload.locked).to be(false)
      expect(Company.pluck(:name)).to eq(["Recorder Co"])
    end
  end

  describe ".snapshot" do
    it "reads direct and grouped links, with each invoice's draft and discarded state" do
      direct_entry = recorder_spec_entry
      grouped_entry = recorder_spec_entry
      invoice = recorder_spec_sent_invoice("RC-0001")
      create(:invoice_line_item, invoice:, timesheet_entry: direct_entry, rate: 100, quantity: 60)
      recorder_spec_aggregate_line(invoice, [grouped_entry])

      facts = described_class.snapshot(company)

      expect(facts[:entries]).to contain_exactly(
        { id: direct_entry.id, locked: false }, { id: grouped_entry.id, locked: false })
      expect(facts[:links]).to contain_exactly(
        { entry_id: direct_entry.id, invoice_id: invoice.id, draft: false, discarded: false },
        { entry_id: grouped_entry.id, invoice_id: invoice.id, draft: false, discarded: false })
      expect(facts[:invoices]).to eq(invoice.id => "RC-0001")
    end
  end

  describe ".write!" do
    around do |example|
      Dir.mktmpdir do |dir|
        @recorder_spec_path = File.join(dir, "seed_disposition.yml")
        example.run
      end
    end

    it "records a non-draft invoice's unlocked entries, grouped ones included, as reserved" do
      direct_entry = recorder_spec_entry
      grouped_entry = recorder_spec_entry
      invoice = recorder_spec_sent_invoice("RC-0001")
      create(:invoice_line_item, invoice:, timesheet_entry: direct_entry, rate: 100, quantity: 60)
      recorder_spec_aggregate_line(invoice, [grouped_entry])
      expect([direct_entry, grouped_entry].map { |entry| entry.reload.locked }).to eq([false, false])

      described_class.write!(path: @recorder_spec_path, as_of: "2026-10-23")

      expect(YAML.load_file(@recorder_spec_path)).to eq(
        "as_of" => "2026-10-23",
        "companies" => {
          "Recorder Co" => {
            "RC-0001" => { "entry_ids" => [direct_entry.id, grouped_entry.id].sort, "disposition" => "reserve" }
          }
        }
      )
    end

    it "writes nothing when a company has an orphan" do
      orphan = recorder_spec_entry(locked: true)

      expect { described_class.write!(path: @recorder_spec_path, as_of: "2026-10-23") }
        .to raise_error(described_class::Error, /Recorder Co has orphans: entries #{orphan.id}/)
      expect(File).not_to exist(@recorder_spec_path)
    end

    it "writes nothing when an invoice links another company's entry" do
      other_company = create(:company)
      other_project = create(:project, client: create(:client, company: other_company), billable: true)
      other_user = create(:user, current_workspace_id: other_company.id)
      foreign_entry = create(:timesheet_entry, user: other_user, project: other_project, bill_status: "unbilled")
      line = create(:invoice_line_item, invoice: recorder_spec_sent_invoice("RC-0002"), rate: 100, quantity: 60)
      line.update_columns(timesheet_entry_id: foreign_entry.id)

      expect { described_class.write!(path: @recorder_spec_path, as_of: "2026-10-23") }
        .to raise_error(described_class::Error, /invoices linking entries of another company: entries #{foreign_entry.id}/)
      expect(File).not_to exist(@recorder_spec_path)
    end

    it "keeps the previous file when the run fails" do
      File.write(@recorder_spec_path, "previous\n")
      recorder_spec_entry(locked: true)

      expect { described_class.write!(path: @recorder_spec_path, as_of: "2026-10-23") }
        .to raise_error(described_class::Error)
      expect(File.read(@recorder_spec_path)).to eq("previous\n")
    end
  end
end
