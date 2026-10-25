# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimekeepingContract do
  # Reads the column names of timesheet_entries straight from db/schema.rb, so
  # a column added there without a matching snapshot field fails this spec.
  def timesheet_entries_columns_from_schema
    schema = File.read(File.expand_path("../../../db/schema.rb", __dir__))
    table = schema[/create_table "timesheet_entries".*?\n  end\n/m]
    ["id"] + table.scan(/^\s+t\.\w+ "(\w+)"/).flatten
  end

  def route_signatures(contract)
    contract.fetch("routes").values.map { |route| "#{route.fetch("method")} #{route.fetch("path")}" }
  end

  describe ".load" do
    it "gives the snapshot entry exactly the timesheet_entries columns plus company_id and version" do
      entry_fields = described_class.load(:entry_snapshots).fetch("entry_fields")

      expect(entry_fields).to match_array(timesheet_entries_columns_from_schema + ["company_id", "version"])
      expect(entry_fields.size).to eq(21)
    end

    it "carries schema_version 1 and the exact snapshot batch and item keys" do
      contract = described_class.load(:entry_snapshots)

      expect(contract.fetch("schema_version")).to eq(1)
      expect(contract.fetch("batch_fields")).to eq(["schema_version", "snapshots"])
      expect(contract.fetch("item_fields")).to eq(["generation", "outbox_position", "entry"])
    end

    it "raises for an unknown contract name" do
      expect { described_class.load(:invoices) }.to raise_error(TimekeepingContract::UnknownContractError, /invoices/)
    end

    it "lists exactly the three prepare conflict reasons" do
      expect(described_class.load(:reservations).fetch("conflict_reasons"))
        .to eq(["on_another_invoice", "provisional_elsewhere", "not_found"])
    end

    it "holds the save reconciliation table with its three outcomes" do
      table = described_class.load(:reservations).fetch("save_reconciliation")
      outcomes = table.fetch("rows").map { |row| row.fetch("outcome") } + [table.fetch("fallback").fetch("outcome")]

      expect(outcomes).to eq(["existing_success", "save_failed", "reconciliation_error"])
      expect(table.fetch("rows").map { |row| [row.fetch("remote_state"), row.fetch("intent_state")] })
        .to eq([["committed", "committed"], ["aborted", "failed"]])
      expect(table.fetch("fallback").fetch("retryable")).to be(true)
    end

    it "contains every entry API route" do
      expect(route_signatures(described_class.load(:entry_api))).to contain_exactly(
        "POST /v1/companies/{company_id}/entries",
        "PATCH /v1/companies/{company_id}/entries/{entry_id}",
        "DELETE /v1/companies/{company_id}/entries/{entry_id}",
        "GET /v1/companies/{company_id}/entries/{entry_id}",
        "GET /v1/companies/{company_id}/entries",
        "POST /v1/companies/{company_id}/entries/bulk-move",
        "POST /v1/companies/{company_id}/entries/bulk-delete"
      )
      expect(described_class.load(:entry_api).dig("routes", "index", "query")).to eq(["from", "to", "user_id", "project_id"])
    end

    it "contains every reservation and service command route" do
      expect(route_signatures(described_class.load(:reservations))).to contain_exactly(
        "POST /v1/companies/{company_id}/reservations/prepare",
        "POST /v1/companies/{company_id}/reservations/commit",
        "POST /v1/companies/{company_id}/reservations/abort",
        "POST /v1/companies/{company_id}/invoices/{invoice_id}/mark-billed",
        "POST /v1/companies/{company_id}/agents/{agent_id}/detach-entries"
      )
    end

    it "contains the snapshot delivery route" do
      expect(route_signatures(described_class.load(:entry_snapshots)))
        .to eq(["POST /internal/v1/timekeeping/entry-snapshots"])
    end

    it "loads the idempotency rules with the 422 reuse answer" do
      contract = described_class.load(:idempotency)

      expect(contract.fetch("receipt_scope")).to eq(["company_scope", "actor_type", "actor_id", "operation", "key"])
      expect(contract.dig("errors", "key_reused")).to eq("status" => 422, "body" => { "reason" => "idempotency_key_reused" })
      expect(contract.fetch("key_sources").keys).to contain_exactly("entry_api", "reservations", "entry_snapshots")
    end

    it "returns a deeply frozen contract" do
      contract = described_class.load(:entry_snapshots)

      expect(contract).to be_frozen
      expect(contract.fetch("entry_fields")).to be_frozen
      expect(contract.fetch("entry_fields").first).to be_frozen
    end
  end
end
