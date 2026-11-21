# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimekeepingProjectionRelay do
  def projection_relay_prepare_owner
    TimekeepingOwnership.current.update!(owner: "monolith", monolith_store: "prepared", handoff_step: nil)
  end

  # Writes one entry through the prepared store's local owner, as an owner of
  # the company, and returns the stored Timekeeping::LocalEntry.
  def projection_relay_prepared_entry(company, note)
    user = create(:user)
    create(:employment, company:, user:)
    user.add_role("owner", company)
    project = create(:project, client: create(:client, company:))
    created = Timekeeping::LocalOwner.call(
      operation: :create, company_id: company.id, generation: TimekeepingOwnership.current.generation.to_s,
      actor: Timekeeping::LocalOwner::Actor.user(user_id: user.id, role: "owner"),
      params: { "idempotency_key" => SecureRandom.uuid,
                "body" => { "project_id" => project.id, "work_date" => Date.current.iso8601, "duration" => 30.0,
                            "note" => note, "source" => "manual", "source_metadata" => {} } }
    )
    expect(created.status).to be_between(200, 201)
    Timekeeping::LocalEntry.where(company_id: company.id).order(:id).last
  end

  it "relay_local_entries_to_projection projects each company's prepared entry under its own company_id only" do
    projection_relay_prepare_owner
    company_a = create(:company)
    company_b = create(:company)
    entry_a = projection_relay_prepared_entry(company_a, "company A private note")
    entry_b = projection_relay_prepared_entry(company_b, "company B private note")

    expect(relay_local_entries_to_projection(company_a)).to be_nil
    relay_local_entries_to_projection(company_b)

    # Each company's entry lands in the shared projection table under its own company and nowhere else.
    expect(TimesheetEntry.unscoped.find(entry_a.id)).to have_attributes(company_id: company_a.id,
                                                                         note: "company A private note")
    expect(TimesheetEntry.unscoped.find(entry_b.id)).to have_attributes(company_id: company_b.id,
                                                                         note: "company B private note")
    expect(TimesheetEntry.unscoped.where(company_id: company_a.id).pluck(:note)).to eq(["company A private note"])
    expect(TimesheetEntry.unscoped.where(company_id: company_b.id).pluck(:note)).to eq(["company B private note"])
  end

  it "relay_local_entries_to_projection raises only for the company whose outbox row stays unsent" do
    projection_relay_prepare_owner
    company_a = create(:company)
    entry_a = projection_relay_prepared_entry(company_a, "company A entry")

    # Company B's only outbox row carries an incomplete snapshot, so the consumer refuses it and it stays unsent.
    company_b = create(:company)
    payload = Timekeeping::SnapshotBatch::ENTRY_FIELDS.index_with { nil }.merge(
      "id" => 9_486_001, "company_id" => company_b.id, "duration" => 45.0, "version" => 1
    )
    refused_row = Timekeeping::LocalOutboxEntry.create!(company_id: company_b.id, entry_id: 9_486_001, generation: 1,
                                                        payload:, created_at: Time.current)

    # Another company's refused row must not fail this company's delivery.
    expect { relay_local_entries_to_projection(company_a) }.not_to raise_error
    expect(TimesheetEntry.unscoped.find(entry_a.id).company_id).to eq(company_a.id)
    expect(Timekeeping::LocalOutboxEntry.where(company_id: company_a.id, sent_at: nil)).not_to exist

    expect { relay_local_entries_to_projection(company_b) }
      .to raise_error(TimekeepingProjectionRelay::Undelivered, /company #{company_b.id}/)
    expect(refused_row.reload.sent_at).to be_nil
    expect(TimesheetEntry.unscoped.where(id: 9_486_001)).not_to exist
  end

  it "relay_local_entries_to_projection delivers a prepared-store entry with its multi-line note and marks the outbox sent", owner_state: "rollback" do
    projection_relay_prepare_owner
    company = create(:company)
    note = "Programming - Built landing\nand tests"
    entry = projection_relay_prepared_entry(company, note)
    expect(Timekeeping::LocalEntry.where(company_id: company.id).count).to eq(1)
    expect(TimesheetEntry.unscoped.where(id: entry.id)).not_to exist

    expect(relay_local_entries_to_projection(company)).to be_nil

    projected = TimesheetEntry.unscoped.find(entry.id)
    expect(projected).to have_attributes(note:, duration: 30.0, company_id: company.id)
    expect(Timekeeping::LocalOutboxEntry.where(company_id: company.id, sent_at: nil)).not_to exist

    relay_local_entries_to_projection(company)
    expect(TimesheetEntry.unscoped.where(id: entry.id).count).to eq(1)
  end

  it "relay_local_entries_to_projection makes no relay call when the legacy store owns entries", owner_state: "legacy" do
    company = create(:company)
    allow(Timekeeping::RelayJob).to receive(:perform_now)

    expect(relay_local_entries_to_projection(company)).to be_nil

    expect(Timekeeping::RelayJob).not_to have_received(:perform_now)
  end

  it "relay helper raises when the generation moved after the write instead of leaving the row silently missing" do
    projection_relay_prepare_owner
    company = create(:company)
    entry_id = projection_relay_prepared_entry(company, "written before the move").id

    # The consumer refuses snapshots of an earlier generation, so delivery after the move must fail loudly.
    TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).increment!(:generation)

    expect { relay_local_entries_to_projection(company) }
      .to raise_error(TimekeepingProjectionRelay::Undelivered, /company #{company.id}/)
    expect(TimesheetEntry.unscoped.where(id: entry_id)).not_to exist
    expect(Timekeeping::LocalOutboxEntry.where(company_id: company.id, sent_at: nil)).to exist
  end
end
