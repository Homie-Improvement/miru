# frozen_string_literal: true

require "rails_helper"

# The seeds write their entries through the model, so this checks that every
# seeded entry of both demo businesses stores the company its project's client
# belongs to.
RSpec.describe "Seeded timesheet entry companies" do
  seeded_businesses = ["Fork & Leaf Salads", "Copper Kettle Bakery"].freeze

  it "creates the ownership record and stores project -> client -> company as every seeded entry's company_id" do
    allow($stdout).to receive(:write)
    # A database loaded from db/schema.rb starts with no ownership row.
    TimekeepingOwnership.delete_all
    load Rails.root.join("db/seeds.rb")

    expect(TimekeepingOwnership.pluck(:generation, :owner, :handoff_step)).to eq([[1, "monolith", nil]])

    seeded_businesses.each do |name|
      company = Company.find_by!(name:)
      entries = TimesheetEntry.joins(project: :client).where(clients: { company_id: company.id })

      expect(entries.count).to be_positive, "#{name} has no seeded entries"
      expect(entries.where.not(company_id: company.id).or(entries.where(company_id: nil)).count)
        .to eq(0), "#{name} has entries whose company_id is not #{company.id}"
    end
  end
end
