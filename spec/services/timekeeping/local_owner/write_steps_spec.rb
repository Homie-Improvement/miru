# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner::WriteSteps do
  let(:ownership) { TimekeepingOwnership.current }

  def prepare_ownership(**attributes)
    ownership.update!({ owner: "monolith", monolith_store: "prepared", handoff_step: nil }.merge(attributes))
  end

  describe ".admitted_generation" do
    it "answers the stored generation while the prepared monolith owns the entries" do
      prepare_ownership

      expect(described_class.admitted_generation).to eq(ownership.reload.generation)
    end

    it "answers nil while a handoff step is set" do
      prepare_ownership(handoff_step: "freeze", final_outbox_position: 0)

      expect(described_class.admitted_generation).to be_nil
    end

    it "answers nil while the entries are not owned by the prepared monolith" do
      prepare_ownership(owner: "timekeeping")

      expect(Timekeeping::EntryOwner.for(ownership.reload)).not_to eq(:prepared)
      expect(described_class.admitted_generation).to be_nil
    end
  end

  describe ".generation_matches?" do
    it "matches only the stored generation sent as a plain integer" do
      expect(described_class.generation_matches?("3", 3)).to be(true)
      expect(described_class.generation_matches?(3, 3)).to be(true)
    end

    it "refuses nil, a value that is not an integer, a different integer and a nil stored generation" do
      expect(described_class.generation_matches?(nil, 3)).to be(false)
      expect(described_class.generation_matches?("abc", 3)).to be(false)
      expect(described_class.generation_matches?("4", 3)).to be(false)
      expect(described_class.generation_matches?("3", nil)).to be(false)
    end
  end

  describe ".write_outbox" do
    it "inserts one row per entry carrying the company, the generation and the entry snapshot" do
      company = create(:company)
      project = create(:project, client: create(:client, company_id: company.id))
      user = create(:user)
      entries = Array.new(2) do
        Timekeeping::LocalEntry.create!(company_id: company.id, project_id: project.id, user_id: user.id,
                                        work_date: Date.new(2026, 3, 2), duration: 60.0, bill_status: "unbilled")
      end
      rows = described_class.reserved_rows(company.id, entries.map(&:id))

      described_class.write_outbox(company_id: company.id, rows: entries.map { |entry| rows.fetch(entry.id) },
                                   generation: 7)

      written = Timekeeping::LocalOutboxEntry.where(company_id: company.id).order(:outbox_position)
      expect(written.map { |row| [row.entry_id, row.generation] }).to eq(entries.map { |entry| [entry.id, 7] })
      expect(written.map { |row| row.payload.fetch("id") }).to eq(entries.map(&:id))
      expect(written.map { |row| row.payload.fetch("locked") }).to eq([false, false])
    end

    it "inserts nothing for no rows" do
      expect { described_class.write_outbox(company_id: 1, rows: [], generation: 1) }
        .not_to change(Timekeeping::LocalOutboxEntry, :count)
    end
  end

  describe "receipt bodies" do
    it "replays a body read back from a fresh row as the Hash that was stored" do
      company = create(:company)
      body = { "billed" => 2, "conflicts" => [{ "entry_id" => 5, "reason" => "not_found" }] }
      Timekeeping::LocalOwner::ServiceReceipt.create!(
        company_id: company.id, actor_name: "invoice-boundary", operation: "mark_billed 501", key: SecureRandom.uuid,
        fingerprint: "f", status: 200, body: described_class.receipt_body(body), created_at: Time.current
      )

      stored = Timekeeping::LocalOwner::ServiceReceipt.find_by!(company_id: company.id).body

      expect(described_class.replayed_body(stored)).to eq(body)
    end
  end
end
