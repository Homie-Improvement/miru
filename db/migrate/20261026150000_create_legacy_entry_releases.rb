# frozen_string_literal: true

# The entries a legacy-store operation removes from its invoice. A reservation
# request carries only the desired set, and the invoice's holding is
# overwritten when the operation settles, so prepare records the removals here
# for commit to apply later. Prepare writes the row in the invoice transaction,
# so a rolled-back save leaves no row and abort has nothing to undo.
class CreateLegacyEntryReleases < ActiveRecord::Migration[8.1]
  def change
    create_table :legacy_entry_releases do |t|
      t.bigint :company_id, null: false
      t.bigint :invoice_id, null: false
      t.uuid :operation_id, null: false
      t.bigint :entry_ids, array: true, null: false, default: []
      t.datetime :applied_at
      t.datetime :created_at, null: false

      # Carries the company, like the outbox index, so one company's operation
      # id never collides with another's.
      t.index %i[company_id operation_id], unique: true,
        name: "index_legacy_entry_releases_on_company_operation"
    end
  end
end
