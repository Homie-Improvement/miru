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

ActiveRecord::Schema[8.1].define(version: 2026_07_01_000000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "admission", force: :cascade do |t|
    t.bigint "generation", default: 1
    t.bigint "held_generation"
    t.check_constraint "id = 1", name: "admission_single_row_check"
  end

  create_table "audit_events", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "entry_id", null: false
    t.string "actor_type", null: false
    t.bigint "actor_id"
    t.string "action", null: false
    t.jsonb "before"
    t.jsonb "after", null: false
    t.datetime "entry_created_at", null: false
    t.datetime "created_at", null: false
    t.string "actor_name"
    t.index ["company_id", "entry_id"], name: "index_audit_events_on_company_id_and_entry_id"
    t.check_constraint "actor_type::text = 'service'::text AND actor_name IS NOT NULL OR actor_type::text <> 'service'::text AND actor_id IS NOT NULL", name: "audit_events_actor_check"
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
    t.string "actor_name", null: false
    t.string "state", null: false
    t.bigint "desired_entry_ids", default: [], null: false, array: true
    t.string "disposition", null: false
    t.bigint "generation", null: false
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.index ["company_id", "actor_name", "operation_id"], name: "index_invoice_operations_on_operation_key", unique: true
    t.index ["company_id", "id", "operation_id"], name: "index_invoice_operations_on_owner_key", unique: true
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
    t.datetime "enqueued_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.datetime "sent_at"
    t.index ["company_id", "enqueued_at"], name: "index_outbox_snapshots_unsent_by_company", where: "(sent_at IS NULL)"
    t.index ["company_id", "id"], name: "index_outbox_snapshots_on_company_id_and_id"
    t.index ["outbox_position"], name: "index_outbox_snapshots_unsent_by_position", where: "(sent_at IS NULL)"
  end

  create_table "reservations", id: false, force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "entry_id", null: false
    t.bigint "invoice_id", null: false
    t.string "state", null: false
    t.string "disposition", null: false
    t.uuid "operation_id", null: false
    t.datetime "created_at", null: false
    t.bigint "invoice_operation_id"
    t.index ["company_id", "entry_id"], name: "index_reservations_on_company_id_and_entry_id"
    t.index ["company_id", "entry_id"], name: "index_reservations_one_committed_per_entry", unique: true, where: "((state)::text = 'committed'::text)"
    t.index ["company_id", "entry_id"], name: "index_reservations_one_provisional_per_entry", unique: true, where: "((state)::text = 'provisional'::text)"
    t.index ["company_id", "invoice_operation_id"], name: "index_reservations_on_company_id_and_invoice_operation_id"
    t.check_constraint "disposition::text = ANY (ARRAY['active'::character varying, 'retained'::character varying]::text[])", name: "reservations_disposition_check"
    t.check_constraint "state::text = ANY (ARRAY['provisional'::character varying, 'committed'::character varying]::text[])", name: "reservations_state_check"
  end

  create_table "service_idempotency_receipts", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "actor_name", null: false
    t.string "operation", null: false
    t.string "key", null: false
    t.string "fingerprint", null: false
    t.integer "status", null: false
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.index ["company_id", "actor_name", "operation", "key"], name: "index_service_idempotency_receipts_on_receipt_key", unique: true
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.string "concurrency_key", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.text "error"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "queue_name", null: false
    t.string "class_name", null: false
    t.text "arguments"
    t.integer "priority", default: 0, null: false
    t.string "active_job_id"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.string "queue_name", null: false
    t.datetime "created_at", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.bigint "supervisor_id"
    t.integer "pid", null: false
    t.string "hostname"
    t.text "metadata"
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "task_key", null: false
    t.datetime "run_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.string "key", null: false
    t.string "schedule", null: false
    t.string "command", limit: 2048
    t.string "class_name"
    t.text "arguments"
    t.string "queue_name"
    t.integer "priority", default: 0
    t.boolean "static", default: true, null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "scheduled_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.string "key", null: false
    t.integer "value", default: 1, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
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
  add_foreign_key "reservations", "invoice_operations", column: ["company_id", "invoice_operation_id", "operation_id"], primary_key: ["company_id", "id", "operation_id"], name: "fk_reservations_owning_operation"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
end
