# frozen_string_literal: true

require "rails_helper"

# Timekeeping admitted entry bodies up to JSON's default 100 levels before it
# capped new bodies lower, and the relay never skips a stored snapshot. The
# receiver must therefore accept the deepest such entry inside its batch.
RSpec.describe "Internal::V1::Timekeeping::EntrySnapshots nesting", type: :request do
  let(:nesting_company) { create(:company) }
  let(:nesting_project) { create(:project, client: create(:client, company: nesting_company)) }
  let(:nesting_user) { create(:user).tap { |user| create(:employment, company: nesting_company, user:) } }

  def nested_metadata(levels)
    levels.times.reduce("leaf") { |value, _| { "child" => value } }
  end

  def nesting_batch(entry_id, proof_metadata)
    entry = TimekeepingContract.load(:entry_snapshots).fetch("entry_fields").index_with(nil).merge(
      "id" => entry_id, "company_id" => nesting_company.id, "version" => 1, "project_id" => nesting_project.id,
      "user_id" => nesting_user.id, "work_date" => "2026-03-02", "duration" => 60.0, "bill_status" => "unbilled",
      "review_status" => "not_required", "locked" => false, "source" => "manual", "source_metadata" => {},
      "proof_metadata" => proof_metadata, "created_at" => "2026-03-02T09:00:00Z",
      "updated_at" => "2026-03-02T09:00:00Z"
    )
    { "schema_version" => 1, "snapshots" => [{ "generation" => 1, "outbox_position" => 1, "entry" => entry }] }
  end

  def post_nesting_batch(batch)
    with_timekeeping_service_token do |token|
      post "/internal/v1/timekeeping/entry-snapshots", params: JSON.generate(batch, max_nesting: false),
        headers: { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json",
                   "Idempotency-Key" => SecureRandom.uuid }
    end
  end

  it "applies an entry whose body sat at JSON's default limit of 100 levels" do
    # The body is one level, so its metadata held at most 99 nested objects.
    metadata = nested_metadata(99)

    post_nesting_batch(nesting_batch(90_401, metadata))

    expect(response).to have_http_status(:ok)
    expect(TimesheetEntry.find(90_401).proof_metadata).to eq(metadata)
  end

  it "refuses a batch nested deeper than any body Timekeeping could admit, writing nothing" do
    post_nesting_batch(nesting_batch(90_402, nested_metadata(100)))

    expect(response).not_to have_http_status(:ok)
    expect(TimesheetEntry.where(id: 90_402)).to be_empty
  end
end
