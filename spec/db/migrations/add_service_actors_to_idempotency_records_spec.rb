# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261028120000_add_service_actors_to_idempotency_records")

# Runs inside the example's transaction, so every schema change and inserted
# row rolls back after the example.
RSpec.describe AddServiceActorsToIdempotencyRecords do
  let(:connection) { ActiveRecord::Base.connection }

  def migrate_service_actors(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
  end

  it "running down and up leaves invoice_operations, its actor_name column and its operation key index exactly as they were" do
    invoice_operations_shape = lambda do
      {
        columns: connection.columns(:invoice_operations).to_h { |column| [column.name, [column.sql_type, column.null]] },
        indexes: connection.indexes(:invoice_operations).to_h { |index| [index.name, [index.columns, index.unique, index.where]] }
      }
    end
    before = invoice_operations_shape.call

    # "That part already holds on `main`. ... Do not add them again, and do not edit any existing migration."
    expect(before[:columns].fetch("actor_name")).to eq(["character varying", false])
    expect(before[:indexes]).to have_key("index_invoice_operations_on_operation_key")

    migrate_service_actors(:down)
    expect(invoice_operations_shape.call).to eq(before)

    migrate_service_actors(:up)
    expect(invoice_operations_shape.call).to eq(before)
  end

  # "The migration runs up and down on an empty idempotency_records table and refuses to run when the table holds rows"
  it "runs down and up on an empty idempotency_records table and refuses both directions while it holds a row" do
    shape = lambda do
      columns = connection.columns(:idempotency_records).to_h { |column| [column.name, column.null] }
      {
        actor_id_nullable: columns["actor_id"],
        has_actor_name: columns.key?("actor_name"),
        has_check: connection.check_constraints(:idempotency_records).any? { |check| check.name == "idempotency_records_actor_check" },
        service_index: connection.indexes(:idempotency_records).any? do |index|
          index.unique && index.columns == %w[company_id actor_type actor_name operation key] && index.where.to_s.include?("service")
        end
      }
    end
    applied = { actor_id_nullable: true, has_actor_name: true, has_check: true, service_index: true }
    reverted = { actor_id_nullable: false, has_actor_name: false, has_check: false, service_index: false }

    expect(shape.call).to eq(applied)
    migrate_service_actors(:down)
    expect(shape.call).to eq(reverted)
    migrate_service_actors(:up)
    expect(shape.call).to eq(applied)

    connection.execute(<<~SQL.squish)
      INSERT INTO idempotency_records (company_id, actor_type, actor_id, actor_name, operation, key, fingerprint, status, body, created_at)
      VALUES (1, 'service', NULL, 'billing-worker', 'reserve', 'k-1', 'fp', 200, '{}', now())
    SQL
    expect { migrate_service_actors(:down) }
      .to raise_error(AddServiceActorsToIdempotencyRecords::TableNotEmptyError, /idempotency_records/)
    expect(shape.call).to eq(applied)
  end

  it "refuses to run up while idempotency_records holds a user receipt and leaves actor_id NOT NULL with no actor_name" do
    migrate_service_actors(:down)
    connection.execute(<<~SQL.squish)
      INSERT INTO idempotency_records (company_id, actor_type, actor_id, operation, key, fingerprint, status, body, created_at)
      VALUES (1, 'User', 7, 'create', 'k-1', 'digest', 201, '{"a":1}', now())
    SQL

    # "The migration runs up and down on an empty idempotency_records table and refuses to run when the table holds rows"
    expect { migrate_service_actors(:up) }
      .to raise_error(described_class::TableNotEmptyError, /idempotency_records/)
    columns = connection.columns(:idempotency_records).to_h { |column| [column.name, column.null] }
    expect(columns).not_to have_key("actor_name")
    expect(columns.fetch("actor_id")).to be(false)
    expect(connection.check_constraints(:idempotency_records).map(&:name))
      .not_to include("idempotency_records_actor_check")
  end

  it "refuses to roll back while a service receipt with no actor_id is stored, and keeps actor_name and the nullable actor_id" do
    connection.execute(<<~SQL.squish)
      INSERT INTO idempotency_records (company_id, actor_type, actor_id, actor_name, operation, key, fingerprint, status, body, created_at)
      VALUES (1, 'service', NULL, 'billing-worker', 'reserve', 'svc-k', 'fp', 200, '{}', now())
    SQL

    # "Use it in both `up` and `down`." Restoring actor_id NOT NULL here would
    # either fail half way or throw away the service receipt's actor_name.
    expect { migrate_service_actors(:down) }
      .to raise_error(AddServiceActorsToIdempotencyRecords::TableNotEmptyError, /idempotency_records/)

    columns = connection.columns(:idempotency_records).index_by(&:name)
    expect(columns).to include("actor_name")
    expect(columns.fetch("actor_id").null).to be(true)
    expect(connection.check_constraints(:idempotency_records).map(&:name)).to include("idempotency_records_actor_check")
    expect(connection.select_rows("SELECT actor_name, actor_id FROM idempotency_records WHERE key = 'svc-k'"))
      .to eq([["billing-worker", nil]])
  end
end
