# frozen_string_literal: true

# One row for each company in a snapshot batch the projection refused with
# 409 stale_generation (docs/architecture/timekeeping-soa.md section 11.3).
# The refused batch rolls back, so without this record the refusal leaves no
# trace for the alert task. handoff_step is copied from the ownership record
# at the moment of the refusal, so a refusal made during a handoff stays
# marked as such after the handoff ends.
class CreateTimekeepingStaleGenerationRefusals < ActiveRecord::Migration[8.1]
  def change
    create_table :timekeeping_stale_generation_refusals do |t|
      t.bigint :company_id, null: false
      t.string :handoff_step
      t.datetime :created_at, null: false

      t.index :created_at
    end
  end
end
