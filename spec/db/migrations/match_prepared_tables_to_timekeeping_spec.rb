# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261025120200_match_prepared_tables_to_timekeeping")
require Rails.root.join("db/migrate/20261026130000_match_prepared_tables_to_timekeeping_service_actors")

# Runs the migration's down and up inside the example's transaction, so every
# column it drops or adds is rolled back after the example.
RSpec.describe MatchPreparedTablesToTimekeeping do
  let(:connection) { ActiveRecord::Base.connection }

  # The later migration that adds service actors builds on these columns, so it
  # is rolled back first to put the tables at the shape this migration made.
  before do
    ActiveRecord::Migration.suppress_messages { MatchPreparedTablesToTimekeepingServiceActors.new.migrate(:down) }
  end

  # [SQL type, nullable] per column, as Postgres reports them.
  bigint = ["bigint", false]
  string = ["character varying", false]
  timestamp = ["timestamp(6) without time zone", false]

  timekeeping_audit_columns = {
    "id" => bigint, "company_id" => bigint, "entry_id" => bigint, "actor_type" => string,
    "actor_id" => bigint, "action" => string, "before" => ["jsonb", true], "after" => ["jsonb", false],
    "entry_created_at" => timestamp, "created_at" => timestamp
  }.freeze
  timekeeping_receipt_columns = {
    "id" => bigint, "company_id" => bigint, "actor_type" => string, "actor_id" => bigint,
    "operation" => string, "key" => string, "fingerprint" => string, "status" => ["integer", false],
    "body" => ["text", false], "created_at" => timestamp
  }.freeze
  prepared_audit_columns = {
    "id" => bigint, "company_id" => bigint, "entry_id" => bigint, "actor_type" => string,
    "actor_id" => ["character varying", true], "action" => string, "changed_fields" => ["jsonb", false],
    "created_at" => timestamp
  }.freeze
  prepared_receipt_columns = {
    "id" => bigint, "company_id" => bigint, "actor_type" => string, "actor_id" => string,
    "operation" => string, "key" => string, "request_digest" => string,
    "response_status" => ["integer", false], "response_body" => ["jsonb", false],
    "created_at" => timestamp, "expires_at" => timestamp
  }.freeze

  def run_migration(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
  end

  def shape(table)
    connection.columns(table).to_h { |column| [column.name, [column.sql_type, column.null]] }
  end

  def insert_entry(company_id)
    connection.select_value(<<~SQL.squish)
      INSERT INTO entries (company_id, project_id, user_id, work_date, duration, bill_status, created_at, updated_at)
      VALUES (#{company_id}, 1, 1, CURRENT_DATE, 60, 'unbilled', now(), now()) RETURNING id
    SQL
  end

  def insert_old_audit
    entry_id = insert_entry(1)
    connection.execute(<<~SQL.squish)
      INSERT INTO entry_audits (company_id, entry_id, actor_type, actor_id, action, created_at)
      VALUES (1, #{entry_id}, 'User', '7', 'update', now())
    SQL
  end

  def insert_old_receipt
    connection.execute(<<~SQL.squish)
      INSERT INTO idempotency_records
        (company_id, actor_type, actor_id, operation, key, request_digest, response_status, created_at, expires_at)
      VALUES (1, 'User', '7', 'create', 'k-1', 'digest', 201, now(), now() + interval '1 day')
    SQL
  end

  it "gives entry_audits and idempotency_records Timekeeping's columns, types and nullability" do
    expect(shape(:entry_audits)).to eq(timekeeping_audit_columns)
    expect(shape(:idempotency_records)).to eq(timekeeping_receipt_columns)
  end

  it "restores each table's earlier shape on rollback and Timekeeping's shape on the way up" do
    run_migration(:down)

    expect(shape(:entry_audits)).to eq(prepared_audit_columns)
    expect(shape(:idempotency_records)).to eq(prepared_receipt_columns)

    run_migration(:up)

    expect(shape(:entry_audits)).to eq(timekeeping_audit_columns)
    expect(shape(:idempotency_records)).to eq(timekeeping_receipt_columns)
  end

  it "refuses to run up while entry_audits holds a row, and changes neither table" do
    run_migration(:down)
    insert_old_audit

    expect { run_migration(:up) }
      .to raise_error(MatchPreparedTablesToTimekeeping::TableNotEmptyError, /entry_audits/)
    expect(shape(:entry_audits)).to eq(prepared_audit_columns)
    expect(shape(:idempotency_records)).to eq(prepared_receipt_columns)
  end

  it "refuses to run up while idempotency_records holds a row, and changes neither table" do
    run_migration(:down)
    insert_old_receipt

    expect { run_migration(:up) }
      .to raise_error(MatchPreparedTablesToTimekeeping::TableNotEmptyError, /idempotency_records/)
    expect(shape(:entry_audits)).to eq(prepared_audit_columns)
    expect(shape(:idempotency_records)).to eq(prepared_receipt_columns)
  end

  it "refuses to roll back while a table holds a Timekeeping-shaped row, and keeps the new columns" do
    connection.execute(<<~SQL.squish)
      INSERT INTO idempotency_records (company_id, actor_type, actor_id, operation, key, fingerprint, status, body, created_at)
      VALUES (1, 'User', 7, 'create', 'k-1', '{"a":1}', 201, '{"a": 1}', now())
    SQL

    expect { run_migration(:down) }
      .to raise_error(MatchPreparedTablesToTimekeeping::TableNotEmptyError, /idempotency_records/)
    expect(shape(:entry_audits)).to eq(timekeeping_audit_columns)
    expect(shape(:idempotency_records)).to eq(timekeeping_receipt_columns)
  end

  it "still refuses an audit row that points at another company's entry" do
    entry_id = insert_entry(1)

    expect {
      connection.execute(<<~SQL.squish)
        INSERT INTO entry_audits (company_id, entry_id, actor_type, actor_id, action, after, entry_created_at, created_at)
        VALUES (2, #{entry_id}, 'User', 7, 'create', '{}', now(), now())
      SQL
    }.to raise_error(ActiveRecord::InvalidForeignKey)
  end
end
