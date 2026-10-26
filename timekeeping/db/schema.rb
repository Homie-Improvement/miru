# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_06_01_000000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "admission", force: :cascade do |t|
    t.bigint "generation", default: 1
    t.check_constraint "id = 1", name: "admission_single_row_check"
  end

  create_table "audit_events", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "entry_id", null: false
    t.string "actor_type", null: false
    t.bigint "actor_id", null: false
    t.string "action", null: false
    t.jsonb "before"
    t.jsonb "after", null: false
    t.datetime "entry_created_at", null: false
    t.datetime "created_at", null: false
    t.index ["company_id", "entry_id"], name: "index_audit_events_on_company_id_and_entry_id"
  end

  create_table "entries", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.integer "version", default: 1, null: false
    t.bigint "project_id", null: false
    t.bigint "user_id", null: false
    t.bigint "agent_id"
    t.date "work_date", null: false
    t.float "duration", null: false
    t.text "note", default: ""
    t.string "bill_status", null: false
    t.string "review_status", default: "not_required", null: false
    t.boolean "locked", default: false
    t.string "source", default: "manual", null: false
    t.jsonb "source_metadata", default: {}, null: false
    t.string "external_run_id"
    t.string "external_session_id"
    t.text "proof_url"
    t.jsonb "proof_metadata", default: {}, null: false
    t.datetime "discarded_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "id"], name: "index_entries_on_company_id_and_id", unique: true
    t.index ["company_id", "project_id", "work_date"], name: "index_entries_on_company_id_and_project_id_and_work_date"
    t.index ["company_id", "user_id", "work_date"], name: "index_entries_on_company_id_and_user_id_and_work_date"
  end

  create_table "idempotency_receipts", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "actor_type", null: false
    t.bigint "actor_id", null: false
    t.string "operation", null: false
    t.string "key", null: false
    t.string "fingerprint", null: false
    t.integer "status", null: false
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.index ["company_id", "actor_type", "actor_id", "operation", "key"], name: "index_idempotency_receipts_on_receipt_key", unique: true
  end

  create_table "invoice_operations", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "invoice_id", null: false
    t.uuid "operation_id", null: false
    t.string "state", null: false
    t.bigint "desired_entry_ids", default: [], null: false, array: true
    t.string "disposition", null: false
    t.bigint "generation", null: false
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.index ["company_id", "invoice_id"], name: "index_invoice_operations_one_prepared_per_invoice", unique: true, where: "((state)::text = 'prepared'::text)"
    t.check_constraint "disposition::text = ANY (ARRAY['active'::character varying, 'retained'::character varying]::text[])", name: "invoice_operations_disposition_check"
    t.check_constraint "state::text = ANY (ARRAY['prepared'::character varying, 'committed'::character varying, 'aborted'::character varying]::text[])", name: "invoice_operations_state_check"
  end

  create_table "outbox_snapshots", primary_key: "outbox_position", force: :cascade do |t|
    t.bigint "id", null: false
    t.bigint "project_id", null: false
    t.bigint "user_id", null: false
    t.bigint "agent_id"
    t.date "work_date", null: false
    t.float "duration", null: false
    t.text "note"
    t.string "bill_status", null: false
    t.string "review_status", null: false
    t.boolean "locked", null: false
    t.string "source", null: false
    t.jsonb "source_metadata", null: false
    t.string "external_run_id"
    t.string "external_session_id"
    t.text "proof_url"
    t.jsonb "proof_metadata", null: false
    t.datetime "discarded_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "company_id", null: false
    t.integer "version", null: false
    t.bigint "generation", null: false
    t.index ["company_id", "id"], name: "index_outbox_snapshots_on_company_id_and_id"
  end

  create_table "reservations", id: false, force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "entry_id", null: false
    t.bigint "invoice_id", null: false
    t.string "state", null: false
    t.string "disposition", null: false
    t.uuid "operation_id", null: false
    t.datetime "created_at", null: false
    t.index ["company_id", "entry_id"], name: "index_reservations_on_company_id_and_entry_id"
    t.index ["company_id", "entry_id"], name: "index_reservations_one_committed_per_entry", unique: true, where: "((state)::text = 'committed'::text)"
    t.index ["company_id", "entry_id"], name: "index_reservations_one_provisional_per_entry", unique: true, where: "((state)::text = 'provisional'::text)"
    t.check_constraint "disposition::text = ANY (ARRAY['active'::character varying, 'retained'::character varying]::text[])", name: "reservations_disposition_check"
    t.check_constraint "state::text = ANY (ARRAY['provisional'::character varying, 'committed'::character varying]::text[])", name: "reservations_state_check"
  end

  create_table "write_metric_events", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "window_start", null: false
    t.bigint "writes", null: false
    t.bigint "reference_unavailable", null: false
    t.bigint "latency_ms", null: false
    t.string "latency_bucket", null: false
    t.index ["company_id"], name: "index_write_metric_events_on_company_id"
  end

  create_table "write_metric_windows", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "window_start", null: false
    t.bigint "writes", default: 0, null: false
    t.bigint "reference_unavailable", default: 0, null: false
    t.bigint "latency_ms_sum", default: 0, null: false
    t.jsonb "latency_ms_buckets", default: {}, null: false
    t.index ["company_id", "window_start"], name: "index_write_metric_windows_on_company_id_and_window_start", unique: true
  end

  add_foreign_key "reservations", "entries", column: ["company_id", "entry_id"], primary_key: ["company_id", "id"]
end
