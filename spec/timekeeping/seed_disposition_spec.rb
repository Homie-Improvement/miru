# frozen_string_literal: true

require "rails_helper"

# Pins the checked-in seed disposition against a fresh load of the demo seed,
# as docs/architecture/timekeeping-soa.md section 10.4 asks: the orphan and
# conflict lists are empty, and the unlocked-link list equals the record.
RSpec.describe "Timekeeping recorded seed disposition", :two_tenant_seed do
  let(:recorded) { YAML.load_file(Timekeeping::SeedDispositionRecorder::DEFAULT_PATH) }
  let(:seeded_companies) { [fork_and_leaf, copper_kettle] }

  def seed_disposition_classification(company)
    facts = Timekeeping::SeedDispositionRecorder.snapshot(company)
    Timekeeping::Preflight.classify(entries: facts[:entries], links: facts[:links])
  end

  it "loads both seeded businesses, each with its own users, entries and invoices" do
    expect(Company.pluck(:name)).to contain_exactly("Fork & Leaf Salads", "Copper Kettle Bakery")

    seeded_companies.each do |company|
      expect(company.users).to exist
      expect(TimesheetEntry.joins(project: :client).where(clients: { company_id: company.id })).to exist
      expect(Invoice.where(company_id: company.id)).to exist
    end
    expect(fork_and_leaf.users.where(id: copper_kettle.users.select(:id)).pluck(:email))
      .to all(eq("grace@forkandleaf.example"))
  end

  it "links each company's invoices only to that company's entries" do
    seeded_companies.each do |company|
      facts = Timekeeping::SeedDispositionRecorder.snapshot(company)
      foreign_entry_ids = facts[:links].pluck(:entry_id).uniq - facts[:entries].pluck(:id)

      expect(foreign_entry_ids).to be_empty, "#{company.name} invoices link other companies' entries: #{foreign_entry_ids}"
    end
  end

  it "has no orphans and no conflicts" do
    seeded_companies.each do |company|
      classification = seed_disposition_classification(company)

      expect(classification[:orphans]).to be_empty, "#{company.name} orphans: #{classification[:orphans]}"
      expect(classification[:conflicts]).to be_empty, "#{company.name} conflicts: #{classification[:conflicts]}"
    end
  end

  it "records exactly the live unlocked-link list, company by company" do
    live = Timekeeping::SeedDisposition.record(
      Timekeeping::SeedDispositionRecorder.classify_companies, as_of: recorded.fetch("as_of"))

    expect(Timekeeping::SeedDisposition.verify(recorded:, live:)).to be_empty
    seeded_companies.each do |company|
      expect(recorded.dig("companies", company.name)).to eq(live.dig("companies", company.name))
    end
    expect(recorded).to eq(live)
  end

  it "lists real invoices of each company, every one reserved" do
    listed = recorded.fetch("companies")
    expect(listed.keys).to contain_exactly("Fork & Leaf Salads", "Copper Kettle Bakery")
    expect(listed.values.sum(&:size)).to be_positive

    listed.each do |company_name, invoices|
      company = Company.find_by!(name: company_name)
      expect(Invoice.where(company_id: company.id).pluck(:invoice_number)).to include(*invoices.keys)
      expect(invoices.values.pluck("disposition").uniq).to eq([Timekeeping::SeedDisposition::RESERVE])
    end
  end

  it "writes, from the loaded seed, a file identical to the checked-in one" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "seed_disposition.yml")

      Timekeeping::SeedDispositionRecorder.write!(path:, as_of: recorded.fetch("as_of"))

      expect(File.read(path)).to eq(File.read(Timekeeping::SeedDispositionRecorder::DEFAULT_PATH))
    end
  end
end
