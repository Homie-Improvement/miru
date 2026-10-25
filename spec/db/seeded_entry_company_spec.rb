# frozen_string_literal: true

require "rails_helper"

# The seeds write their entries through the model, so this checks that every
# seeded entry of both demo businesses stores the company its project's client
# belongs to.
RSpec.describe "Seeded timesheet entry companies" do
  seeded_businesses = ["Fork & Leaf Salads", "Copper Kettle Bakery"].freeze

  it "stores project -> client -> company as company_id on every entry of both seeded businesses" do
    allow($stdout).to receive(:write)
    load Rails.root.join("db/seeds.rb")

    seeded_businesses.each do |name|
      company = Company.find_by!(name:)
      entries = TimesheetEntry.joins(project: :client).where(clients: { company_id: company.id })

      expect(entries.count).to be_positive, "#{name} has no seeded entries"
      expect(entries.where.not(company_id: company.id).or(entries.where(company_id: nil)).count)
        .to eq(0), "#{name} has entries whose company_id is not #{company.id}"
    end
  end
end
