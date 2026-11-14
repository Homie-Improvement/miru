require "rails_helper"

RSpec.describe "idempotency_records service actors" do
  let(:connection) { ActiveRecord::Base.connection }

  # "Add a unique partial index on `(company_id, actor_type, actor_name, operation, key)` for service rows."
  # The index carries company_id, so one company's service receipt never blocks another company's.
  it "accepts the same service receipt key in two companies, because service receipt uniqueness is scoped by company_id" do
    insert_service_receipt = lambda do |company_id|
      connection.execute(<<~SQL.squish)
        INSERT INTO idempotency_records
          (company_id, actor_type, actor_id, actor_name, operation, key, fingerprint, status, body, created_at)
        VALUES (#{company_id}, 'service', NULL, 'billing-sync', 'reserve', 'k-1', 'fp', 201, '{}', now())
      SQL
    end

    insert_service_receipt.call(1)
    expect { insert_service_receipt.call(2) }.not_to raise_error

    companies = connection.select_values(<<~SQL.squish)
      SELECT company_id FROM idempotency_records
      WHERE actor_type = 'service' AND actor_name = 'billing-sync' AND operation = 'reserve' AND key = 'k-1'
      ORDER BY company_id
    SQL
    expect(companies).to eq([1, 2])

    # Within one company the same service receipt is still refused.
    expect { insert_service_receipt.call(1) }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end

require "rails_helper"

RSpec.describe "idempotency_records service actors" do
  # "A service row with null `actor_name` is refused. A user row with null `actor_id` is refused."
  # "A user row with `actor_id` inserts as before."
  it "refuses a service row without actor_name and a user row without actor_id, and accepts a user row with actor_id" do
    connection = ActiveRecord::Base.connection
    insert = lambda do |actor_type, actor_id, actor_name, key|
      connection.transaction(requires_new: true) do
        connection.execute(<<~SQL.squish)
          INSERT INTO idempotency_records (company_id, actor_type, actor_id, actor_name, operation, key, fingerprint, status, body, created_at)
          VALUES (1, #{connection.quote(actor_type)}, #{connection.quote(actor_id)}, #{connection.quote(actor_name)},
                  'reserve', #{connection.quote(key)}, 'fp', 200, '{}', now())
        SQL
      end
    end

    expect { insert.call("service", nil, nil, "k-service") }
      .to raise_error(ActiveRecord::CheckViolation, /idempotency_records_actor_check/)
    expect { insert.call("User", nil, nil, "k-user-null") }
      .to raise_error(ActiveRecord::CheckViolation, /idempotency_records_actor_check/)
    expect { insert.call("User", 7, nil, "k-user") }.not_to raise_error
    expect(connection.select_value("SELECT count(*) FROM idempotency_records WHERE key = 'k-user'")).to eq(1)
  end
end

require "rails_helper"

RSpec.describe "idempotency_records service actors" do
  # "Two service rows with the same `(company_id, actor_type, actor_name, operation, key)` are refused."
  # The issue also says the same row under two different actor_names is accepted.
  it "refuses a second service receipt with the same scope and key but accepts one under another actor_name" do
    connection = ActiveRecord::Base.connection
    insert_service = lambda do |actor_name|
      connection.transaction(requires_new: true) do
        connection.execute(<<~SQL.squish)
          INSERT INTO idempotency_records (company_id, actor_type, actor_id, actor_name, operation, key, fingerprint, status, body, created_at)
          VALUES (1, 'service', NULL, #{connection.quote(actor_name)}, 'reserve', 'shared-key', 'fp', 200, '{}', now())
        SQL
      end
    end

    expect { insert_service.call("billing-worker") }.not_to raise_error
    expect { insert_service.call("billing-worker") }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { insert_service.call("payroll-worker") }.not_to raise_error
    expect(connection.select_values("SELECT actor_name FROM idempotency_records WHERE key = 'shared-key' ORDER BY actor_name"))
      .to eq(%w[billing-worker payroll-worker])
  end
end

RSpec.describe "idempotency_records service and user receipts sharing a key" do
  # "The existing `index_idempotency_records_on_scope_and_key` keeps user receipts unique."
  # The service index covers only service rows, so a user receipt with the same
  # operation and key is not blocked by it.
  it "accepts a service receipt and a user receipt with the same operation and key" do
    connection = ActiveRecord::Base.connection
    connection.execute(<<~SQL.squish)
      INSERT INTO idempotency_records (company_id, actor_type, actor_id, actor_name, operation, key, fingerprint, status, body, created_at)
      VALUES (1, 'service', NULL, 'billing-worker', 'reserve', 'shared-by-both', 'fp', 200, '{}', now()),
             (1, 'User', 7, NULL, 'reserve', 'shared-by-both', 'fp', 200, '{}', now())
    SQL

    expect(connection.select_values("SELECT actor_type FROM idempotency_records WHERE key = 'shared-by-both'"))
      .to match_array(%w[User service])
  end
end
