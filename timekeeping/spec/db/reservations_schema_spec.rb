# frozen_string_literal: true

require "rails_helper"

# The reservation rule of docs/architecture/timekeeping-soa.md section 7.2:
# at most one committed and at most one provisional reservation per entry,
# and a reservation only ever points at an entry of its own company.
RSpec.describe "Timekeeping reservations table" do
  def create_schema_spec_entry(company_id)
    Entry.create!(
      company_id:, project_id: 1, user_id: 1, work_date: Date.new(2026, 1, 5),
      duration: 60.0, bill_status: "unbilled"
    )
  end

  def reserve(entry, state:, company_id: entry.company_id)
    Reservation.create!(
      company_id:, entry_id: entry.id, invoice_id: 1, state:,
      disposition: "active", operation_id: SecureRandom.uuid, created_at: Time.current
    )
  end

  let(:entry) { create_schema_spec_entry(1) }

  it "accepts one provisional and one committed reservation for the same entry" do
    reserve(entry, state: "provisional")
    reserve(entry, state: "committed")

    expect(Reservation.where(company_id: 1, entry_id: entry.id).count).to eq(2)
  end

  it "refuses a second committed reservation for the same entry" do
    reserve(entry, state: "committed")

    expect { reserve(entry, state: "committed") }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "refuses a second provisional reservation for the same entry" do
    reserve(entry, state: "provisional")

    expect { reserve(entry, state: "provisional") }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "refuses a reservation whose company differs from its entry's" do
    other_company_entry = create_schema_spec_entry(2)

    expect { reserve(other_company_entry, state: "committed", company_id: 1) }
      .to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it "refuses a state outside provisional and committed" do
    expect { reserve(entry, state: "released") }.to raise_error(ActiveRecord::StatementInvalid)
  end
end
