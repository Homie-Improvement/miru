# frozen_string_literal: true

# One row for each conflict reason in a prepare the reservation port refused
# (docs/architecture/timekeeping-soa.md section 11.3, prepare refusals). A
# refused save usually rolls back, so without this record the refusal leaves
# no trace for the alert task. reason is the conflict reason the port gave,
# nil when it gave none.
class CreateTimekeepingPrepareRefusals < ActiveRecord::Migration[8.1]
  def change
    create_table :timekeeping_prepare_refusals do |t|
      t.bigint :company_id, null: false
      t.string :reason
      t.datetime :created_at, null: false

      t.index :created_at
    end
  end
end
