# frozen_string_literal: true

# Builds entry snapshot payloads for specs from the entry_snapshots contract,
# so a contract change reaches every spec that sends a snapshot from one place.
# It takes plain ids and needs no timekeeping_arrange, so service and request
# specs can call it as well as the shared contract examples.
module TimekeepingSnapshots
  module_function

  # One entry holding every contract entry field. Overrides are merged as
  # given, so a spec can still send a key outside the contract on purpose.
  def entry(id:, company_id:, version:, project_id:, user_id:, **fields)
    contract.fetch("entry_fields").index_with(nil).merge(
      "id" => id, "company_id" => company_id, "version" => version, "project_id" => project_id, "user_id" => user_id,
      "work_date" => "2026-03-02", "duration" => 90.0, "note" => "v#{version}", "bill_status" => "unbilled",
      "review_status" => "not_required", "locked" => false, "source" => "manual", "source_metadata" => {},
      "proof_metadata" => {}, "created_at" => "2026-03-02T09:00:00Z", "updated_at" => "2026-03-02T09:00:00Z"
    ).merge(fields.transform_keys(&:to_s))
  end

  def item(entry, generation:, outbox_position: entry.fetch("version"))
    { "generation" => generation, "outbox_position" => outbox_position, "entry" => entry }
  end

  def batch(*items)
    { "schema_version" => contract.fetch("schema_version"), "snapshots" => items }
  end

  def contract
    TimekeepingContract.load(:entry_snapshots)
  end
end
