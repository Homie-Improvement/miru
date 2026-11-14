# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner::WriteSteps do
  it "is where LocalOwner::Outcome is defined" do
    expect(Timekeeping::LocalOwner::Outcome).to equal(described_class::Outcome)
    expect(Timekeeping::LocalOwner::Outcome.refusal(:unpublishable_entry).status).to eq(422)
  end

  describe ".generation_matches?" do
    it "admits only the stored generation sent as a plain integer" do
      expect(described_class.generation_matches?("4", 4)).to be(true)
      expect(described_class.generation_matches?(4, 4)).to be(true)
      expect(described_class.generation_matches?(nil, 4)).to be(false)
      expect(described_class.generation_matches?("abc", 4)).to be(false)
      expect(described_class.generation_matches?("5", 4)).to be(false)
      expect(described_class.generation_matches?("4", nil)).to be(false)
    end
  end

  describe ".record_flips" do
    let(:company) { create(:company) }
    let(:owner) { timekeeping_member(company, "owner") }
    let(:project) { create(:project, client: create(:client, company:)) }
    let(:invoice) { create(:invoice, company:, client: project.client) }
    let(:actor) { { actor_type: "service", actor_name: "invoices" } }

    def create_write_steps_entry(note)
      Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                      work_date: Date.current, duration: 30.0, note:, bill_status: "unbilled")
    end

    def reserve_for_write_steps(entry)
      ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql_array([
        "INSERT INTO reservations (company_id, entry_id, invoice_id, operation_id, state, disposition, created_at) " \
        "VALUES (?, ?, ?, ?, 'provisional', 'active', now())",
        company.id, entry.id, invoice.id, SecureRandom.uuid
      ]))
    end

    def locked_rows(entries)
      Timekeeping::LocalEntry.with_reserved.where(company_id: company.id, id: entries.map(&:id)).order(:id).to_a
    end

    it "writes version + 1, one audit row and one snapshot for each entry whose flag flipped, and nothing for the rest" do
      flipping = create_write_steps_entry("flips")
      steady = create_write_steps_entry("steady")
      before = locked_rows([flipping, steady])
      reserve_for_write_steps(flipping)
      audits = Timekeeping::LocalOwner::AuditRow.count
      outbox = Timekeeping::LocalOutboxEntry.count
      steps = []

      flipped = described_class.record_flips(company_id: company.id, entries: before, actor:, action: "prepare",
                                             generation: 3, checkpoint: ->(step) { steps << step })

      expect(flipped).to eq([flipping.id])
      expect(flipping.reload.version).to eq(before.first.version + 1)
      expect(steady.reload.version).to eq(before.last.version)
      audit = Timekeeping::LocalOwner::AuditRow.order(:id).last
      expect(Timekeeping::LocalOwner::AuditRow.count).to eq(audits + 1)
      expect(audit.attributes).to include("entry_id" => flipping.id, "actor_type" => "service", "actor_name" => "invoices",
                                          "actor_id" => nil, "action" => "prepare",
                                          "before" => { "locked" => false }, "after" => { "locked" => true })
      expect(Timekeeping::LocalOutboxEntry.count).to eq(outbox + 1)
      expect(steps).to eq(%i[entry_written audit_written outbox_written])
    end

    it "raises with the entry id and refused field name, before any audit or outbox row, for an unpublishable flip" do
      entry = create_write_steps_entry("bad")
      entry.update_columns(source: "legacy")
      before = locked_rows([entry])
      reserve_for_write_steps(entry)
      audits = Timekeeping::LocalOwner::AuditRow.count
      outbox = Timekeeping::LocalOutboxEntry.count

      expect {
        described_class.record_flips(company_id: company.id, entries: before, actor:, action: "prepare",
                                     generation: 3, checkpoint: ->(_step) { })
      }.to raise_error(described_class::UnpublishableRows) { |error|
        expect(error.entries).to eq(entry.id => ["source"])
        expect(error.message).not_to include("legacy")
        expect(error.outcome.status).to eq(422)
        expect(error.outcome.body).to eq("reason" => "unpublishable_entry",
                                         "entries" => [{ "entry_id" => entry.id, "fields" => ["source"] }])
      }
      expect(Timekeeping::LocalOwner::AuditRow.count).to eq(audits)
      expect(Timekeeping::LocalOutboxEntry.count).to eq(outbox)
    end
  end
end
