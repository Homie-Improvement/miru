# frozen_string_literal: true

require "rails_helper"
require "open3"
require "pg"
require "securerandom"

RSpec.describe "TenantStateDigest refusal of non-test Timekeeping databases" do
  before do
    allow(PG).to receive(:connect).and_call_original
    allow(PG::Connection).to receive(:new).and_call_original
  end

  # "A database name that does not end in \_test is refused before connecting, with no URL in the error"
  it "take refuses a Timekeeping database whose name does not end in _test before connecting, in URL and keyword form, naming only the database" do
    user = "digest_guard_user"
    password = "digest-guard-secret-41c9"
    host = "db.invalid"
    forms = {
      "URL" => ->(name) { "postgres://#{user}:#{password}@#{host}:5432/#{name}" },
      "keyword" => ->(name) { "host=#{host} port=5432 user=#{user} password=#{password} dbname=#{name}" }
    }

    forms.each do |form, conninfo_for|
      %w[timekeeping_demo timekeeping_test_copy timekeeping_TEST timekeeping_test_backup].each do |name|
        conninfo = conninfo_for.call(name)

        expect { TenantStateDigest.take(company_id: 1, timekeeping_url: conninfo) }
          .to raise_error(TestDatabaseGuard::NotATestDatabase) { |error|
            expect(error.message).to include(name), "#{form} #{name}"
            expect(error.message).not_to include(password)
            expect(error.message).not_to include(user)
            expect(error.message).not_to include(host)
            expect(error.message).not_to include(conninfo)
          }
      end
    end

    expect(PG).not_to have_received(:connect)
    expect(PG::Connection).not_to have_received(:new)
  end
end

RSpec.describe "TenantStateDigest refusal when URL readings disagree" do
  before do
    allow(PG).to receive(:connect).and_call_original
    allow(PG::Connection).to receive(:new).and_call_original
  end

  # "Call `IntegratedRuntime.require_test_database_url!(url)` before `PG.connect`. It uses
  # `TestDatabaseGuard.require_test_database!`, and its error names only the database, never the URL."
  # libpq reads the dbname parameter and Active Record reads the path, so both must name a _test database.
  it "take refuses a URL whose path and dbname parameter disagree on a _test name, before connecting and without the URL" do
    user = "digest_mixed_user"
    password = "digest-mixed-secret-9a2e"
    host = "db.invalid"
    base = "postgres://#{user}:#{password}@#{host}:5432"
    urls = {
      "timekeeping_demo" => "#{base}/timekeeping_test?dbname=timekeeping_demo",
      "timekeeping_live" => "#{base}/timekeeping_live?dbname=timekeeping_test"
    }

    urls.each do |refused_name, url|
      expect { TenantStateDigest.take(company_id: 1, timekeeping_url: url) }
        .to raise_error(TestDatabaseGuard::NotATestDatabase) { |error|
          expect(error.message).to include(refused_name)
          expect(error.message).not_to include(password)
          expect(error.message).not_to include(user)
          expect(error.message).not_to include(host)
          expect(error.message).not_to include(url)
        }
    end

    expect(PG).not_to have_received(:connect)
    expect(PG::Connection).not_to have_received(:new)
  end
end

RSpec.describe "TenantStateDigest.timekeeping refusal of non-test databases" do
  before do
    allow(PG).to receive(:connect).and_call_original
    allow(PG::Connection).to receive(:new).and_call_original
  end

  # "A database name that does not end in \_test is refused before connecting, with no URL in the error"
  it "the Timekeeping-only digest refuses a non-test database name before connecting, naming only the database" do
    user = "digest_side_user"
    password = "digest-side-secret-5f07"
    host = "db.invalid"
    url = "postgres://#{user}:#{password}@#{host}:5432/timekeeping_development"

    expect { TenantStateDigest.timekeeping(company_id: 1, timekeeping_url: url) }
      .to raise_error(TestDatabaseGuard::NotATestDatabase) { |error|
        expect(error.message).to include("timekeeping_development")
        expect(error.message).not_to include(password)
        expect(error.message).not_to include(user)
        expect(error.message).not_to include(host)
        expect(error.message).not_to include(url)
      }
    expect(PG).not_to have_received(:connect)
    expect(PG::Connection).not_to have_received(:new)
  end
end

RSpec.describe "TenantStateDigest connection failures" do
  # "Connect the way `TimekeepingDatabaseReset.connect` does in `spec/support/timekeeping/timekeeping_database_reset.rb`."
  # That connect replaces the driver's error, which can carry the host, with one naming only the database.
  it "take raises a connection error naming only the database when a _test Timekeeping database cannot be reached" do
    user = "digest_unreachable_user"
    password = "digest-unreachable-secret-c3d8"
    url = "postgres://#{user}:#{password}@127.0.0.1:1/timekeeping_unreachable_test"

    expect { TenantStateDigest.take(company_id: 1, timekeeping_url: url) }
      .to raise_error(PG::ConnectionBad) { |error|
        expect(error.message).to include("timekeeping_unreachable_test")
        expect(error.message).not_to include(password)
        expect(error.message).not_to include(user)
        expect(error.message).not_to include("127.0.0.1")
        expect(error.message).not_to include(url)
        expect(error.cause).to be_nil
      }
  end
end

RSpec.describe TenantStateDigest do
  it "group_digest keeps a NULL column distinct from an empty string in row_to_json text" do
    connection = ActiveRecord::Base.connection
    null_row = connection.select_value("SELECT row_to_json(t)::text FROM (SELECT NULL::text AS proof_url) t")
    empty_row = connection.select_value("SELECT row_to_json(t)::text FROM (SELECT ''::text AS proof_url) t")

    # "Serialise each row with `row_to_json(t)::text`, which keeps NULL distinct from an empty string."
    expect(null_row).not_to eq(empty_row)

    # "Changing a value from NULL to an empty string changes the digest."
    null_digest = described_class.group_digest([["entries", [null_row]]])
    empty_digest = described_class.group_digest([["entries", [empty_row]]])
    expect(null_digest).to match(/\A\h{64}\z/)
    expect(empty_digest).to match(/\A\h{64}\z/)
    expect(null_digest).not_to eq(empty_digest)
  end
end


RSpec.describe TenantStateDigest do
  # "A `bill_status` flip on one company changes only that company's monolith digest."
  it "a bill_status flip on one company's timesheet entry changes only that company's monolith digest" do
    company_a = create(:company)
    company_b = create(:company)
    entry_a = create(:timesheet_entry)
    entry_a.update_columns(company_id: company_a.id)
    entry_b = create(:timesheet_entry)
    entry_b.update_columns(company_id: company_b.id)

    before_a = described_class.monolith(company_id: company_a.id)
    before_b = described_class.monolith(company_id: company_b.id)

    other_status = (TimesheetEntry.bill_statuses.keys - [entry_a.reload.bill_status]).first
    entry_a.update_columns(bill_status: other_status)

    after_a = described_class.monolith(company_id: company_a.id)
    after_b = described_class.monolith(company_id: company_b.id)

    expect(after_a.fetch(:projection)).not_to eq(before_a.fetch(:projection))
    expect(after_b).to eq(before_b)
  end
end


RSpec.describe TenantStateDigest do
  # "Two takes with no write in between are equal, `reservations` rows included."
  it "two monolith takes with no write in between are equal with a reservations row present" do
    company = create(:company)
    empty_company = create(:company)
    connection = ActiveRecord::Base.connection
    entry_id = connection.select_value(ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, company.id]))
      INSERT INTO entries (company_id, bill_status, duration, project_id, user_id, work_date, created_at, updated_at)
      VALUES (?, 'unbilled', 60, 1, 1, DATE '2025-01-06', now(), now()) RETURNING id
    SQL
    connection.execute(ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, company.id, entry_id]))
      INSERT INTO reservations (company_id, entry_id, invoice_id, state, disposition, operation_id, created_at)
      VALUES (?, ?, 1, 'provisional', 'active', gen_random_uuid(), now())
    SQL
    reservation_count = connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(["SELECT count(*) FROM reservations WHERE company_id = ?", company.id])
    )
    expect(reservation_count).to eq(1)

    first_take = described_class.monolith(company_id: company.id)
    second_take = described_class.monolith(company_id: company.id)

    expect(second_take).to eq(first_take)
    expect(first_take.fetch(:invoice_operations))
      .not_to eq(described_class.monolith(company_id: empty_company.id).fetch(:invoice_operations))
  end
end


RSpec.describe TenantStateDigest do
  # "Changing a value from NULL to an empty string changes the digest."
  it "changing an entries proof_url from NULL to an empty string changes the monolith entries digest" do
    company = create(:company)
    connection = ActiveRecord::Base.connection
    entry_id = connection.select_value(ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, company.id]))
      INSERT INTO entries (company_id, bill_status, duration, project_id, user_id, work_date, proof_url, created_at, updated_at)
      VALUES (?, 'unbilled', 60, 1, 1, DATE '2025-01-06', NULL, now(), now()) RETURNING id
    SQL

    with_null = described_class.monolith(company_id: company.id).fetch(:entries)
    connection.execute(ActiveRecord::Base.sanitize_sql_array(["UPDATE entries SET proof_url = '' WHERE id = ?", entry_id]))
    with_empty_string = described_class.monolith(company_id: company.id).fetch(:entries)

    expect(with_empty_string).not_to eq(with_null)
  end
end


RSpec.describe TenantStateDigest do
  # "Prove \"changes nothing\" with per-tenant digests ... taken before and after each request."
  # A take inside a cached request must still see a write the cache did not record.
  it "a raw write inside the Active Record query cache still changes the next monolith take" do
    company = create(:company)
    entry = create(:timesheet_entry)
    entry.update_columns(company_id: company.id)

    ActiveRecord::Base.cache do
      before_write = described_class.monolith(company_id: company.id).fetch(:projection)
      ActiveRecord::Base.connection.raw_connection.exec_params(
        "UPDATE timesheet_entries SET note = $1 WHERE id = $2", ["changed outside the cache", entry.id]
      )
      after_write = described_class.monolith(company_id: company.id).fetch(:projection)

      expect(after_write).not_to eq(before_write)
    end
  end
end


RSpec.describe "TenantStateDigest tenant isolation" do
  # "A `bill_status` flip on one company changes only that company's monolith digest."
  it "a bill_status flip on company A's timesheet entry changes only A's monolith digest" do
    company_a = create(:company)
    company_b = create(:company)
    connection = ActiveRecord::Base.connection
    [company_a, company_b].each do |company|
      entry = create(:timesheet_entry)
      connection.exec_query("UPDATE timesheet_entries SET company_id = $1 WHERE id = $2", "digest", [company.id, entry.id])
    end

    before_a = TenantStateDigest.monolith(company_id: company_a.id)
    before_b = TenantStateDigest.monolith(company_id: company_b.id)

    connection.exec_query(
      "UPDATE timesheet_entries SET bill_status = CASE WHEN bill_status = 0 THEN 1 ELSE 0 END WHERE company_id = $1",
      "digest", [company_a.id]
    )

    after_a = TenantStateDigest.monolith(company_id: company_a.id)
    expect(after_a.fetch(:projection)).not_to eq(before_a.fetch(:projection))
    expect(TenantStateDigest.monolith(company_id: company_b.id)).to eq(before_b)
  end
end


RSpec.describe "TenantStateDigest tenant isolation" do
  # "For every group in each database, a row inserted for B leaves A's digest equal, and the reverse also holds."
  it "a monolith entries row inserted for company B changes B's entries digest and leaves A's monolith digest equal, and the reverse" do
    company_a_id = 910_001
    company_b_id = 910_002
    insert_entry = lambda do |company_id|
      ActiveRecord::Base.connection.exec_query(
        "INSERT INTO entries (bill_status, company_id, created_at, duration, project_id, updated_at, user_id, work_date) " \
        "VALUES ('unbilled', $1, now(), 60, 1, now(), 1, current_date)",
        "digest", [company_id]
      )
    end

    [[company_b_id, company_a_id], [company_a_id, company_b_id]].each do |writer, other|
      writer_before = TenantStateDigest.monolith(company_id: writer)
      other_before = TenantStateDigest.monolith(company_id: other)

      insert_entry.call(writer)

      expect(TenantStateDigest.monolith(company_id: writer).fetch(:entries)).not_to eq(writer_before.fetch(:entries))
      expect(TenantStateDigest.monolith(company_id: other)).to eq(other_before)
    end
  end
end


RSpec.describe "TenantStateDigest tenant isolation" do
  # "Every query selects only rows whose company equals the argument."
  # The snapshot receipt lists only B: a receipt listing both companies belongs to both digests.
  it "monolith receipts written for company B, including an entry_snapshot_receipts row listing only B, leave A's monolith digest equal" do
    company_a_id = 920_001
    company_b_id = 920_002
    connection = ActiveRecord::Base.connection
    a_before = TenantStateDigest.monolith(company_id: company_a_id)
    b_before = TenantStateDigest.monolith(company_id: company_b_id)

    connection.exec_query(
      "INSERT INTO idempotency_records (actor_id, actor_type, body, company_id, created_at, fingerprint, key, operation, status) " \
      "VALUES (1, 'user', '{}', $1, now(), 'fp', 'digest-key', 'create', 201)",
      "digest", [company_b_id]
    )
    after_records = TenantStateDigest.monolith(company_id: company_b_id).fetch(:receipts)
    expect(after_records).not_to eq(b_before.fetch(:receipts))

    connection.exec_query(
      "INSERT INTO entry_snapshot_receipts (actor, company_ids, created_at, expires_at, key, request_digest, response_status) " \
      "VALUES ('digest-actor', ARRAY[$1]::bigint[], now(), now() + interval '1 day', 'digest-key', 'rd', 200)",
      "digest", [company_b_id]
    )
    expect(TenantStateDigest.monolith(company_id: company_b_id).fetch(:receipts)).not_to eq(after_records)
    expect(TenantStateDigest.monolith(company_id: company_a_id)).to eq(a_before)
  end
end


RSpec.describe "TenantStateDigest tenant isolation" do
  # "A Timekeeping row, or a `service_idempotency_receipts` row, for B changes only B's Timekeeping digest."
  it "a service_idempotency_receipts row for company B changes only B's Timekeeping digest" do
    skip "set TIMEKEEPING_LIVE=1 to use the Timekeeping test database" unless ENV["TIMEKEEPING_LIVE"] == "1"

    url = ENV.fetch("TIMEKEEPING_DATABASE_URL")
    IntegratedRuntime.require_test_database_url!(url)
    output, status = Bundler.with_unbundled_env do
      Open3.capture2e({ "RAILS_ENV" => "test", "BUNDLE_GEMFILE" => Rails.root.join("timekeeping/Gemfile").to_s,
                        "TIMEKEEPING_DATABASE_URL" => url, "DATABASE_URL" => nil },
                      "bundle", "exec", "rails", "db:prepare", chdir: Rails.root.join("timekeeping").to_s)
    end
    raise "db:prepare failed:\n#{output}" unless status.success?

    company_a_id = 930_001
    company_b_id = 930_002
    connection = PG.connect(url)
    begin
      a_before = TenantStateDigest.timekeeping(company_id: company_a_id, timekeeping_url: url)
      b_before = TenantStateDigest.timekeeping(company_id: company_b_id, timekeeping_url: url)

      connection.exec_params(
        "INSERT INTO service_idempotency_receipts (company_id, actor_name, operation, key, fingerprint, status, body, created_at) " \
        "VALUES ($1, 'monolith', 'prepare', 'digest-key', 'fp', 200, '{}', now())",
        [company_b_id]
      )

      b_after = TenantStateDigest.timekeeping(company_id: company_b_id, timekeeping_url: url)
      expect(b_after.fetch(:receipts)).not_to eq(b_before.fetch(:receipts))
      expect(TenantStateDigest.timekeeping(company_id: company_a_id, timekeeping_url: url)).to eq(a_before)
    ensure
      [company_a_id, company_b_id].each do |id|
        connection.exec_params("DELETE FROM service_idempotency_receipts WHERE company_id = $1", [id])
      end
      connection.close
    end
  end
end

RSpec.describe "TenantStateDigest monolith outbox and invoice operation isolation" do
  it "monolith outbox and invoice operation rows for one company change only that company's group digests, in both directions" do
    connection = ActiveRecord::Base.connection
    company_a = 910_001
    company_b = 910_002

    insert_rows = lambda do |writer, other|
      entry_id = writer * 10
      # "For every group in each database, a row inserted for B leaves A's digest equal, and the reverse also holds."
      steps = {
        outbox: "INSERT INTO entry_outbox_items (company_id, generation, entry_id, payload, created_at) " \
                "VALUES (#{writer}, 1, #{entry_id}, '{}', now())",
        invoice_operations: "INSERT INTO invoice_operations (company_id, invoice_id, operation_id, actor_name, state, " \
                            "disposition, generation, created_at) VALUES (#{writer}, 77, gen_random_uuid(), " \
                            "'monolith', 'committed', 'active', 1, now())"
      }
      connection.execute(<<~SQL.squish)
        INSERT INTO entries (id, company_id, project_id, user_id, work_date, duration, note, bill_status, created_at, updated_at)
        VALUES (#{entry_id}, #{writer}, 1, 1, '2026-04-01', 5, 'kept', 'unbilled', now(), now())
      SQL

      steps.each do |group, sql|
        writer_before = TenantStateDigest.monolith(company_id: writer)
        other_before = TenantStateDigest.monolith(company_id: other)
        connection.execute(sql)
        expect(TenantStateDigest.monolith(company_id: writer).fetch(group)).not_to eq(writer_before.fetch(group)), group.to_s
        expect(TenantStateDigest.monolith(company_id: other)).to eq(other_before), group.to_s
      end

      writer_before = TenantStateDigest.monolith(company_id: writer)
      other_before = TenantStateDigest.monolith(company_id: other)
      connection.execute(<<~SQL.squish)
        INSERT INTO reservations (company_id, entry_id, invoice_id, state, disposition, operation_id, created_at)
        VALUES (#{writer}, #{entry_id}, 77, 'committed', 'active', gen_random_uuid(), now())
      SQL
      expect(TenantStateDigest.monolith(company_id: writer).fetch(:invoice_operations))
        .not_to eq(writer_before.fetch(:invoice_operations))
      expect(TenantStateDigest.monolith(company_id: other)).to eq(other_before)
    end

    insert_rows.call(company_b, company_a)
    insert_rows.call(company_a, company_b)
  end
end

RSpec.describe "TenantStateDigest Timekeeping group isolation", :without_transaction do
  it "Timekeeping entries, outbox and invoice operation rows for one company change only that company's Timekeeping group digests, in both directions" do
    skip "set TIMEKEEPING_LIVE=1 to use the Timekeeping test database" unless ENV["TIMEKEEPING_LIVE"] == "1"

    url = ENV.fetch("TIMEKEEPING_DATABASE_URL")
    IntegratedRuntime.require_test_database_url!(url)
    output, status = Bundler.with_unbundled_env do
      Open3.capture2e({ "RAILS_ENV" => "test", "BUNDLE_GEMFILE" => Rails.root.join("timekeeping/Gemfile").to_s,
                        "TIMEKEEPING_DATABASE_URL" => url, "DATABASE_URL" => nil },
                      "bundle", "exec", "rails", "db:prepare", chdir: Rails.root.join("timekeeping").to_s)
    end
    raise "db:prepare failed:\n#{output}" unless status.success?

    company_a = 920_001
    company_b = 920_002
    connection = PG.connect(url)
    digest = ->(company) { TenantStateDigest.timekeeping(company_id: company, timekeeping_url: url) }

    write_for = lambda do |writer, other|
      operation_id = SecureRandom.uuid
      # "For every group in each database, a row inserted for B leaves A's digest equal, and the reverse also holds."
      steps = [
        [:entries, "INSERT INTO entries (id, company_id, project_id, user_id, work_date, duration, bill_status, " \
                   "created_at, updated_at) VALUES ($1 * 10, $1, 1, 1, '2026-04-01', 5, 'unbilled', now(), now())", [writer]],
        [:outbox, "INSERT INTO outbox_snapshots (id, project_id, user_id, work_date, duration, bill_status, review_status, " \
                  "locked, source, source_metadata, proof_metadata, created_at, updated_at, company_id, version, generation) " \
                  "VALUES ($1 * 10, 1, 1, '2026-04-01', 5, 'unbilled', 'not_required', false, 'manual', '{}', '{}', " \
                  "now(), now(), $1, 1, 1)", [writer]],
        [:invoice_operations, "INSERT INTO invoice_operations (company_id, invoice_id, operation_id, actor_name, state, " \
                              "disposition, generation, created_at) VALUES ($1, 77, $2, 'monolith', 'committed', " \
                              "'active', 1, now())", [writer, operation_id]],
        [:invoice_operations, "INSERT INTO reservations (company_id, entry_id, invoice_id, state, disposition, " \
                              "operation_id, created_at) VALUES ($1::bigint, $1::bigint * 10, 77, 'committed', 'active', $2, now())",
         [writer, operation_id]]
      ]
      steps.each do |group, sql, params|
        writer_before = digest.call(writer)
        other_before = digest.call(other)
        connection.exec_params(sql, params)
        expect(digest.call(writer).fetch(group)).not_to eq(writer_before.fetch(group)), group.to_s
        expect(digest.call(other)).to eq(other_before), group.to_s
      end
    end

    write_for.call(company_b, company_a)
    write_for.call(company_a, company_b)
  ensure
    if connection
      [company_a, company_b].compact.each do |id|
        %w[reservations invoice_operations outbox_snapshots entries].each do |table|
          connection.exec_params("DELETE FROM #{connection.quote_ident(table)} WHERE company_id = $1", [id])
        end
      end
      connection.close
    end
  end
end


RSpec.describe "TenantStateDigest" do
  it "take refuses a Timekeeping database name without the _test suffix before any connection and names no URL part" do
    allow(PG).to receive(:connect).and_call_original
    allow(PG::Connection).to receive(:new).and_call_original
    user = "digest_guard_user"
    password = "digest-guard-secret-41c"
    host = "digest-guard.invalid"
    urls = {
      "timekeeping_demo" => "postgres://#{user}:#{password}@#{host}:5432/timekeeping_demo",
      "timekeeping_test_copy" => "host=#{host} port=5432 user=#{user} password=#{password} dbname=timekeeping_test_copy",
      "timekeeping_TEST" => "postgres://#{user}:#{password}@#{host}:5432/timekeeping_TEST"
    }

    # "A database name that does not end in \_test is refused before connecting, with no URL in the error"
    urls.each do |name, url|
      expect { TenantStateDigest.take(company_id: 990_101, timekeeping_url: url) }
        .to raise_error(TestDatabaseGuard::NotATestDatabase) { |error|
          expect(error.message).to include(name)
          expect(error.message).not_to include(password)
          expect(error.message).not_to include(user)
          expect(error.message).not_to include(host)
          expect(error.message).not_to include(url)
        }
    end
    expect(PG).not_to have_received(:connect)
    expect(PG::Connection).not_to have_received(:new)
  end
end


RSpec.describe "TenantStateDigest" do
  it "take refuses a URL whose path and dbname parameter disagree on the _test suffix, in both directions" do
    allow(PG).to receive(:connect).and_call_original
    allow(PG::Connection).to receive(:new).and_call_original
    password = "digest-split-secret-9a7"
    host = "digest-split.invalid"
    urls = [
      "postgres://split_user:#{password}@#{host}:5432/timekeeping_test?dbname=timekeeping_demo",
      "postgres://split_user:#{password}@#{host}:5432/timekeeping_demo?dbname=timekeeping_test"
    ]

    urls.each do |url|
      expect { TenantStateDigest.take(company_id: 990_102, timekeeping_url: url) }
        .to raise_error(TestDatabaseGuard::NotATestDatabase) { |error|
          expect(error.message).to include("timekeeping_demo")
          expect(error.message).not_to include(password)
          expect(error.message).not_to include(host)
          expect(error.message).not_to include(url)
        }
    end
    expect(PG).not_to have_received(:connect)
    expect(PG::Connection).not_to have_received(:new)
  end
end


RSpec.describe "TenantStateDigest" do
  it "timekeeping raises naming only the database when a _test database cannot be reached, and returns no digest" do
    password = "digest-unreachable-secret-3f2"
    url = "host=127.0.0.1 port=1 user=digest_unreachable_user password=#{password} dbname=timekeeping_digest_unreachable_test"

    expect { TenantStateDigest.timekeeping(company_id: 990_103, timekeeping_url: url) }
      .to raise_error(PG::ConnectionBad) { |error|
        expect(error.message).to include("timekeeping_digest_unreachable_test")
        expect(error.message).not_to include(password)
        expect(error.message).not_to include("127.0.0.1")
        expect(error.message).not_to include("digest_unreachable_user")
        expect(error.cause).to be_nil
      }
  end
end


RSpec.describe "TenantStateDigest" do
  it "GROUPS lists exactly the tables the issue names for each group in each database" do
    tables = TenantStateDigest::GROUPS.transform_values do |groups|
      groups.transform_values { |specs| specs.map { |spec| spec.table.to_s } }
    end

    expect(TenantStateDigest::GROUPS).to be_frozen
    expect(tables.keys).to contain_exactly(:monolith, :timekeeping)
    # "Monolith (`db/schema.rb`). Projection: `timesheet_entries`. Entries: `entries`. Receipts: `idempotency_records`,
    # plus `entry_snapshot_receipts` matched by `company_id = ANY(company_ids)`, because that table has only a
    # `company_ids bigint[]` column. Outbox: `entry_outbox_items`. Invoice operations: `invoice_operations` plus `reservations`."
    expect(tables.fetch(:monolith).keys).to contain_exactly(:projection, :entries, :receipts, :outbox, :invoice_operations)
    expect(tables.fetch(:monolith).fetch(:projection)).to contain_exactly("timesheet_entries")
    expect(tables.fetch(:monolith).fetch(:entries)).to contain_exactly("entries")
    expect(tables.fetch(:monolith).fetch(:receipts)).to contain_exactly("idempotency_records", "entry_snapshot_receipts")
    expect(tables.fetch(:monolith).fetch(:outbox)).to contain_exactly("entry_outbox_items")
    expect(tables.fetch(:monolith).fetch(:invoice_operations)).to contain_exactly("invoice_operations", "reservations")
    # "Timekeeping (`timekeeping/db/schema.rb`). Entries: `entries`. Receipts: `idempotency_receipts` plus
    # `service_idempotency_receipts`. Outbox: `outbox_snapshots` (primary key `outbox_position`). Invoice operations:
    # `invoice_operations` plus `reservations`."
    expect(tables.fetch(:timekeeping).keys).to contain_exactly(:entries, :receipts, :outbox, :invoice_operations)
    expect(tables.fetch(:timekeeping).fetch(:entries)).to contain_exactly("entries")
    expect(tables.fetch(:timekeeping).fetch(:receipts)).to contain_exactly("idempotency_receipts", "service_idempotency_receipts")
    expect(tables.fetch(:timekeeping).fetch(:outbox)).to contain_exactly("outbox_snapshots")
    expect(tables.fetch(:timekeeping).fetch(:invoice_operations)).to contain_exactly("invoice_operations", "reservations")
  end
end


RSpec.describe "TenantStateDigest" do
  it "group_digest keeps NULL distinct from an empty string and moves when one row is added to an empty group" do
    empty = TenantStateDigest.group_digest([["entries", []]])

    # "An empty group digests to a fixed value, and a single inserted row changes it."
    expect(empty).to match(/\A\h{64}\z/)
    expect(TenantStateDigest.group_digest([["entries", []]])).to eq(empty)
    expect(TenantStateDigest.group_digest([["entries", ['{"id":1,"note":null}']]])).not_to eq(empty)
    # "Serialise each row with `row_to_json(t)::text`, which keeps NULL distinct from an empty string."
    expect(TenantStateDigest.group_digest([["entries", ['{"id":1,"note":null}']]]))
      .not_to eq(TenantStateDigest.group_digest([["entries", ['{"id":1,"note":""}']]]))
    # The table name is hashed too, so the same rows under another table name differ.
    expect(TenantStateDigest.group_digest([["reservations", []]])).not_to eq(empty)
  end
end


RSpec.describe "TenantStateDigest" do
  it "monolith digest changes for the company whose entries row goes from NULL to empty proof_url and stays equal for another company" do
    company_a = 990_201
    company_b = 990_202
    connection = ActiveRecord::Base.connection
    insert_entry = lambda do |company_id|
      connection.select_value(
        "INSERT INTO entries (bill_status, company_id, created_at, updated_at, duration, project_id, user_id, work_date) " \
        "VALUES ('unbilled', #{Integer(company_id)}, now(), now(), 60, 1, 1, CURRENT_DATE) RETURNING id"
      )
    end
    entry_a = insert_entry.call(company_a)
    insert_entry.call(company_b)
    empty_entries = TenantStateDigest.group_digest([["entries", []]])

    before_a = TenantStateDigest.monolith(company_id: company_a)
    before_b = TenantStateDigest.monolith(company_id: company_b)
    expect(before_a.fetch(:entries)).not_to eq(empty_entries)
    expect(before_b.fetch(:entries)).not_to eq(empty_entries)

    connection.execute("UPDATE entries SET proof_url = '' WHERE id = #{Integer(entry_a)}")

    # "Changing a value from NULL to an empty string changes the digest."
    expect(TenantStateDigest.monolith(company_id: company_a).fetch(:entries)).not_to eq(before_a.fetch(:entries))
    expect(TenantStateDigest.monolith(company_id: company_b)).to eq(before_b)
  end
end


RSpec.describe "TenantStateDigest" do
  it "monolith digest of a company with no rows equals the fixed empty value per group and a single inserted row changes only that group" do
    empty_company = 990_301
    other_empty_company = 990_302

    # "An empty group digests to a fixed value, and a single inserted row changes it."
    first = TenantStateDigest.monolith(company_id: empty_company)
    expect(first.keys).to contain_exactly(:projection, :entries, :receipts, :outbox, :invoice_operations)
    expect(TenantStateDigest.monolith(company_id: other_empty_company)).to eq(first)
    expect(first.fetch(:entries)).to eq(TenantStateDigest.group_digest([["entries", []]]))
    expect(first.values).to all(match(/\A\h{64}\z/))

    ActiveRecord::Base.connection.execute(
      "INSERT INTO entries (bill_status, company_id, created_at, updated_at, duration, project_id, user_id, work_date) " \
      "VALUES ('unbilled', #{empty_company}, now(), now(), 60, 1, 1, CURRENT_DATE)"
    )
    after = TenantStateDigest.monolith(company_id: empty_company)

    expect(after.fetch(:entries)).not_to eq(first.fetch(:entries))
    expect(after.except(:entries)).to eq(first.except(:entries))
    expect(TenantStateDigest.monolith(company_id: other_empty_company)).to eq(first)
  end
end


RSpec.describe "TenantStateDigest" do
  it "monolith receipts digest moves only for the company listed in an entry_snapshot_receipts row and idempotency_records row, in both directions" do
    company_a = 990_401
    company_b = 990_402
    connection = ActiveRecord::Base.connection
    insert_snapshot_receipt = lambda do |company_id, key|
      connection.execute(
        "INSERT INTO entry_snapshot_receipts (actor, company_ids, created_at, expires_at, key, request_digest, response_status) " \
        "VALUES ('digest-spec', ARRAY[#{Integer(company_id)}]::bigint[], now(), now() + interval '1 day', '#{key}', 'digest', 200)"
      )
    end
    insert_idempotency_record = lambda do |company_id, key|
      connection.execute(
        "INSERT INTO idempotency_records (actor_id, actor_type, body, company_id, created_at, fingerprint, key, operation, status) " \
        "VALUES (1, 'user', '{}', #{Integer(company_id)}, now(), 'digest', '#{key}', 'create', 200)"
      )
    end

    # "For every group in each database, a row inserted for B leaves A's digest equal, and the reverse also holds."
    [[company_b, company_a], [company_a, company_b]].each_with_index do |(writer, bystander), index|
      [insert_snapshot_receipt, insert_idempotency_record].each_with_index do |insert, table_index|
        writer_before = TenantStateDigest.monolith(company_id: writer)
        bystander_before = TenantStateDigest.monolith(company_id: bystander)

        insert.call(writer, "digest-spec-#{index}-#{table_index}")

        expect(TenantStateDigest.monolith(company_id: writer).fetch(:receipts)).not_to eq(writer_before.fetch(:receipts))
        expect(TenantStateDigest.monolith(company_id: bystander)).to eq(bystander_before)
      end
    end
  end
end


RSpec.describe "TenantStateDigest" do
  it "monolith digest is equal across two takes with reservations rows present and moves only for the company whose reservation is added" do
    company_a = 990_501
    company_b = 990_502
    connection = ActiveRecord::Base.connection
    add_reservation = lambda do |company_id, invoice_id|
      entry_id = connection.select_value(
        "INSERT INTO entries (bill_status, company_id, created_at, updated_at, duration, project_id, user_id, work_date) " \
        "VALUES ('unbilled', #{Integer(company_id)}, now(), now(), 60, 1, 1, CURRENT_DATE) RETURNING id"
      )
      connection.execute(
        "INSERT INTO reservations (company_id, created_at, disposition, entry_id, invoice_id, operation_id, state) " \
        "VALUES (#{Integer(company_id)}, now(), 'active', #{Integer(entry_id)}, #{Integer(invoice_id)}, " \
        "gen_random_uuid(), 'provisional')"
      )
    end
    add_reservation.call(company_a, 1)
    add_reservation.call(company_b, 2)
    expect(connection.select_value("SELECT count(*) FROM reservations WHERE company_id = #{company_a}").to_i).to eq(1)

    # "Two takes with no write in between are equal, `reservations` rows included."
    first = TenantStateDigest.monolith(company_id: company_a)
    expect(TenantStateDigest.monolith(company_id: company_a)).to eq(first)
    empty = TenantStateDigest.monolith(company_id: 990_599)
    expect(first.fetch(:invoice_operations)).not_to eq(empty.fetch(:invoice_operations))

    b_before = TenantStateDigest.monolith(company_id: company_b)
    add_reservation.call(company_b, 3)

    expect(TenantStateDigest.monolith(company_id: company_b).fetch(:invoice_operations)).not_to eq(b_before.fetch(:invoice_operations))
    expect(TenantStateDigest.monolith(company_id: company_a)).to eq(first)
  end
end


RSpec.describe "TenantStateDigest" do
  it "monolith bill_status flip on one company's timesheet entry changes only that company's projection digest" do
    company_a = create(:company)
    company_b = create(:company)
    entry_a = create(:timesheet_entry)
    entry_b = create(:timesheet_entry)
    connection = ActiveRecord::Base.connection
    connection.execute("UPDATE timesheet_entries SET company_id = #{company_a.id} WHERE id = #{entry_a.id}")
    connection.execute("UPDATE timesheet_entries SET company_id = #{company_b.id} WHERE id = #{entry_b.id}")
    empty_projection = TenantStateDigest.group_digest([["timesheet_entries", []]])

    before_a = TenantStateDigest.monolith(company_id: company_a.id)
    before_b = TenantStateDigest.monolith(company_id: company_b.id)
    expect(before_a.fetch(:projection)).not_to eq(empty_projection)
    expect(before_b.fetch(:projection)).not_to eq(empty_projection)

    connection.execute(
      "UPDATE timesheet_entries SET bill_status = CASE WHEN bill_status = 0 THEN 1 ELSE 0 END WHERE id = #{entry_a.id}"
    )

    # "A `bill_status` flip on one company changes only that company's monolith digest."
    expect(TenantStateDigest.monolith(company_id: company_a.id).fetch(:projection)).not_to eq(before_a.fetch(:projection))
    expect(TenantStateDigest.monolith(company_id: company_b.id)).to eq(before_b)
  end
end


RSpec.describe "TenantStateDigest" do
  it "monolith digest sees a write made through the raw connection inside an Active Record query cache" do
    company_id = 990_601
    connection = ActiveRecord::Base.connection
    entry_id = connection.select_value(
      "INSERT INTO entries (bill_status, company_id, created_at, updated_at, duration, project_id, user_id, work_date) " \
      "VALUES ('unbilled', #{company_id}, now(), now(), 60, 1, 1, CURRENT_DATE) RETURNING id"
    )

    ActiveRecord::Base.cache do
      before = TenantStateDigest.monolith(company_id:).fetch(:entries)
      connection.raw_connection.exec("UPDATE entries SET note = 'written past the query cache' WHERE id = #{Integer(entry_id)}")

      expect(TenantStateDigest.monolith(company_id:).fetch(:entries)).not_to eq(before)
    end
  end
end


RSpec.describe "TenantStateDigest" do
  it "take on the live Timekeeping database moves only B's Timekeeping digest for an entries or service_idempotency_receipts row for B" do
    skip "set TIMEKEEPING_LIVE=1 to use the Timekeeping test database" unless ENV["TIMEKEEPING_LIVE"] == "1"

    url = ENV.fetch("TIMEKEEPING_DATABASE_URL")
    IntegratedRuntime.require_test_database_url!(url)
    output, status = Bundler.with_unbundled_env do
      Open3.capture2e({ "RAILS_ENV" => "test", "BUNDLE_GEMFILE" => Rails.root.join("timekeeping/Gemfile").to_s,
                        "TIMEKEEPING_DATABASE_URL" => url, "DATABASE_URL" => nil },
                      "bundle", "exec", "rails", "db:prepare", chdir: Rails.root.join("timekeeping").to_s)
    end
    raise "db:prepare failed:\n#{output}" unless status.success?

    company_a = 990_701
    company_b = 990_702
    connection = PG.connect(url)
    begin
      connection.exec_params(
        "INSERT INTO entries (company_id, project_id, user_id, work_date, duration, bill_status, created_at, updated_at) " \
        "VALUES ($1, 1, 1, CURRENT_DATE, 60, 'unbilled', now(), now())", [company_a]
      )
      before_a = TenantStateDigest.take(company_id: company_a, timekeeping_url: url)
      before_b = TenantStateDigest.take(company_id: company_b, timekeeping_url: url)
      expect(before_a.keys).to contain_exactly(:monolith, :timekeeping)
      expect(before_a.fetch(:timekeeping).fetch(:entries)).not_to eq(before_b.fetch(:timekeeping).fetch(:entries))

      # "A Timekeeping row, or a `service_idempotency_receipts` row, for B changes only B's Timekeeping digest."
      connection.exec_params(
        "INSERT INTO entries (company_id, project_id, user_id, work_date, duration, bill_status, created_at, updated_at) " \
        "VALUES ($1, 1, 1, CURRENT_DATE, 60, 'unbilled', now(), now())", [company_b]
      )
      after_entry_b = TenantStateDigest.take(company_id: company_b, timekeeping_url: url)
      expect(after_entry_b.fetch(:timekeeping).fetch(:entries)).not_to eq(before_b.fetch(:timekeeping).fetch(:entries))
      expect(TenantStateDigest.take(company_id: company_a, timekeeping_url: url)).to eq(before_a)

      connection.exec_params(
        "INSERT INTO service_idempotency_receipts (company_id, actor_name, operation, key, fingerprint, status, body, created_at) " \
        "VALUES ($1, 'digest-spec', 'create', 'digest-spec-key', 'digest', 200, '{}', now())", [company_b]
      )
      after_receipt_b = TenantStateDigest.take(company_id: company_b, timekeeping_url: url)
      expect(after_receipt_b.fetch(:timekeeping).fetch(:receipts)).not_to eq(after_entry_b.fetch(:timekeeping).fetch(:receipts))
      expect(TenantStateDigest.take(company_id: company_a, timekeeping_url: url)).to eq(before_a)
      expect(TenantStateDigest.take(company_id: company_b, timekeeping_url: url)).to eq(after_receipt_b)
    ensure
      [company_a, company_b].each do |id|
        %w[service_idempotency_receipts entries].each do |table|
          connection.exec_params("DELETE FROM #{connection.quote_ident(table)} WHERE company_id = $1", [id])
        end
      end
      connection.close
    end
  end
end


RSpec.describe TenantStateDigest do
  it "group_digest of no tables is the pinned SHA-256 of nothing and an empty table group is a fixed value that one row moves" do
    # Pinned literal: SHA-256 over zero bytes, which is what a group with no frames hashes.
    expect(described_class.group_digest([])).to eq("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

    # "An empty group digests to a fixed value, and a single inserted row changes it."
    empty_group = [["invoice_operations", []], ["reservations", []]]
    empty_value = described_class.group_digest(empty_group)
    expect(empty_value).to match(/\A\h{64}\z/)
    expect(described_class.group_digest(empty_group.map { |table, rows| [table.dup, rows.dup] })).to eq(empty_value)
    expect(empty_value).not_to eq("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

    one_row = [["invoice_operations", ['{"id":1,"company_id":7}']], ["reservations", []]]
    expect(described_class.group_digest(one_row)).not_to eq(empty_value)

    # The table name is part of the hash, so the same rows under another table name differ.
    renamed = [["invoice_operations", []], ["reservation", []]]
    expect(described_class.group_digest(renamed)).not_to eq(empty_value)
  end
end


RSpec.describe TenantStateDigest do
  it "timekeeping digest of a company with no rows is a fixed value per group, the same for any empty company" do
    skip "set TIMEKEEPING_LIVE=1 to use the Timekeeping test database" unless ENV["TIMEKEEPING_LIVE"] == "1"

    url = ENV.fetch("TIMEKEEPING_DATABASE_URL")
    IntegratedRuntime.require_test_database_url!(url)
    output, status = Bundler.with_unbundled_env do
      Open3.capture2e({ "RAILS_ENV" => "test", "BUNDLE_GEMFILE" => Rails.root.join("timekeeping/Gemfile").to_s,
                        "TIMEKEEPING_DATABASE_URL" => url, "DATABASE_URL" => nil },
                      "bundle", "exec", "rails", "db:prepare", chdir: Rails.root.join("timekeeping").to_s)
    end
    raise "db:prepare failed:\n#{output}" unless status.success?

    # "An empty group digests to a fixed value, and a single inserted row changes it."
    first = described_class.timekeeping(company_id: 9_437_101, timekeeping_url: url)
    second = described_class.timekeeping(company_id: 9_437_102, timekeeping_url: url)

    expect(first.keys).to contain_exactly(:entries, :receipts, :outbox, :invoice_operations)
    expect(second).to eq(first)
    first.each do |group, value|
      expect(value).to match(/\A\h{64}\z/), group.to_s
      expected = described_class.group_digest(
        described_class::GROUPS.fetch(:timekeeping).fetch(group).map { |spec| [spec.table, []] }
      )
      expect(value).to eq(expected), group.to_s
    end
    expect(first.values.uniq.size).to eq(first.size)
  end
end


RSpec.describe TenantStateDigest do
  it "timekeeping digest moves each group for a row in each of its tables and is equal across two takes with a reservation present" do
    skip "set TIMEKEEPING_LIVE=1 to use the Timekeeping test database" unless ENV["TIMEKEEPING_LIVE"] == "1"

    url = ENV.fetch("TIMEKEEPING_DATABASE_URL")
    IntegratedRuntime.require_test_database_url!(url)
    output, status = Bundler.with_unbundled_env do
      Open3.capture2e({ "RAILS_ENV" => "test", "BUNDLE_GEMFILE" => Rails.root.join("timekeeping/Gemfile").to_s,
                        "TIMEKEEPING_DATABASE_URL" => url, "DATABASE_URL" => nil },
                      "bundle", "exec", "rails", "db:prepare", chdir: Rails.root.join("timekeeping").to_s)
    end
    raise "db:prepare failed:\n#{output}" unless status.success?

    company = 9_437_201
    connection = PG.connect(url)
    take = -> { described_class.timekeeping(company_id: company, timekeeping_url: url) }
    now = "2026-01-05 10:00:00"

    # "Each digest covers entries, receipts, outbox, projection rows and invoice operations for that company in its database"
    before = take.call
    entry_id = connection.exec_params(
      "INSERT INTO entries (company_id, project_id, user_id, work_date, duration, bill_status, created_at, updated_at) " \
      "VALUES ($1, 1, 1, '2026-01-05', 60, 'unbilled', $2, $2) RETURNING id", [company, now]
    ).getvalue(0, 0)
    after_entry = take.call
    expect(after_entry[:entries]).not_to eq(before[:entries])

    connection.exec_params(
      "INSERT INTO idempotency_receipts (company_id, actor_type, actor_id, operation, key, fingerprint, status, body, created_at) " \
      "VALUES ($1, 'user', 1, 'create', 'k1', 'f1', 201, '{}', $2)", [company, now]
    )
    after_receipt = take.call
    expect(after_receipt[:receipts]).not_to eq(after_entry[:receipts])

    connection.exec_params(
      "INSERT INTO service_idempotency_receipts (company_id, actor_name, operation, key, fingerprint, status, body, created_at) " \
      "VALUES ($1, 'monolith', 'prepare', 'k2', 'f2', 200, '{}', $2)", [company, now]
    )
    after_service_receipt = take.call
    expect(after_service_receipt[:receipts]).not_to eq(after_receipt[:receipts])

    connection.exec_params(
      "INSERT INTO outbox_snapshots (id, project_id, user_id, work_date, duration, bill_status, review_status, locked, " \
      "source, source_metadata, proof_metadata, created_at, updated_at, company_id, version, generation) " \
      "VALUES ($1, 1, 1, '2026-01-05', 60, 'unbilled', 'not_required', false, 'manual', '{}', '{}', $2, $2, $3, 1, 1)",
      [entry_id, now, company]
    )
    after_outbox = take.call
    expect(after_outbox[:outbox]).not_to eq(after_service_receipt[:outbox])

    operation_id = SecureRandom.uuid
    connection.exec_params(
      "INSERT INTO invoice_operations (company_id, invoice_id, operation_id, actor_name, state, disposition, generation, created_at) " \
      "VALUES ($1, 77, $2, 'monolith', 'prepared', 'active', 1, $3)", [company, operation_id, now]
    )
    after_operation = take.call
    expect(after_operation[:invoice_operations]).not_to eq(after_outbox[:invoice_operations])

    connection.exec_params(
      "INSERT INTO reservations (company_id, entry_id, invoice_id, state, disposition, operation_id, created_at) " \
      "VALUES ($1, $2, 77, 'provisional', 'active', $3, $4)", [company, entry_id, operation_id, now]
    )
    after_reservation = take.call
    expect(after_reservation[:invoice_operations]).not_to eq(after_operation[:invoice_operations])

    # "Two takes with no write in between are equal, `reservations` rows included."
    expect(connection.exec_params("SELECT count(*) FROM reservations WHERE company_id = $1", [company]).getvalue(0, 0).to_i)
      .to be >= 1
    expect(take.call).to eq(after_reservation)
  ensure
    if connection
      %w[reservations invoice_operations outbox_snapshots service_idempotency_receipts idempotency_receipts entries].each do |table|
        connection.exec_params("DELETE FROM #{connection.quote_ident(table)} WHERE company_id = $1", [company])
      end
      connection.close
    end
  end
end


RSpec.describe "TenantStateDigest" do
  # "A database name that does not end in \_test is refused before connecting, with no URL in the error"
  # libpq reads the dbname parameter while the path still names a _test database, so a check of the
  # path alone would let this URL through to a non-test database.
  it "take refuses a URL whose path ends in _test but whose dbname parameter does not, before connecting and without the URL" do
    allow(PG).to receive(:connect).and_call_original
    allow(PG::Connection).to receive(:new).and_call_original
    url = "postgres://digest_guard_user:digest-guard-secret@db.invalid:5432/timekeeping_test?dbname=timekeeping_demo"

    expect { TenantStateDigest.take(company_id: 1, timekeeping_url: url) }
      .to raise_error(TestDatabaseGuard::NotATestDatabase) { |error|
        expect(error.message).to include("timekeeping_demo")
        expect(error.message).not_to include("digest-guard-secret")
        expect(error.message).not_to include("digest_guard_user")
        expect(error.message).not_to include("db.invalid")
        expect(error.message).not_to include(url)
      }
    expect(PG).not_to have_received(:connect)
    expect(PG::Connection).not_to have_received(:new)
  end
end


RSpec.describe "TenantStateDigest" do
  # "A database name that does not end in \_test is refused before connecting, with no URL in the error"
  # Active Record reads the path while libpq reads the dbname parameter, so a check of the dbname
  # parameter alone would let this URL through.
  it "take refuses a URL whose dbname parameter ends in _test but whose path does not, before connecting and without the URL" do
    allow(PG).to receive(:connect).and_call_original
    allow(PG::Connection).to receive(:new).and_call_original
    url = "postgres://digest_guard_user:digest-guard-secret@db.invalid:5432/timekeeping_demo?dbname=timekeeping_test"

    expect { TenantStateDigest.take(company_id: 1, timekeeping_url: url) }
      .to raise_error(TestDatabaseGuard::NotATestDatabase) { |error|
        expect(error.message).to include("timekeeping_demo")
        expect(error.message).not_to include("digest-guard-secret")
        expect(error.message).not_to include("digest_guard_user")
        expect(error.message).not_to include("db.invalid")
        expect(error.message).not_to include(url)
      }
    expect(PG).not_to have_received(:connect)
    expect(PG::Connection).not_to have_received(:new)
  end
end


RSpec.describe "TenantStateDigest" do
  # "An empty group digests to a fixed value, and a single inserted row changes it."
  # A database that cannot be read must never digest as empty: equal before and after values would
  # then claim a request changed nothing when nothing was read.
  it "timekeeping raises instead of returning a digest when a _test database cannot be reached, naming only the database" do
    password = "digest-unreachable-secret"
    conninfo = "host=127.0.0.1 port=1 user=digest_harness_user password=#{password} dbname=timekeeping_digest_unreachable_test"

    expect { TenantStateDigest.timekeeping(company_id: 1, timekeeping_url: conninfo) }
      .to raise_error(PG::ConnectionBad) { |error|
        expect(error.message).to include("timekeeping_digest_unreachable_test")
        expect(error.message).not_to include(password)
        expect(error.message).not_to include("digest_harness_user")
        expect(error.message).not_to include("127.0.0.1")
        expect(error.cause).to be_nil
      }
  end
end


RSpec.describe "TenantStateDigest" do
  # "A `bill_status` flip on one company changes only that company's monolith digest."
  # A write through the raw connection does not clear Active Record's query cache, so a digest that
  # reused a cached result would report no change for a real write.
  it "monolith sees a bill_status flip made inside an Active Record query cache through the raw connection" do
    company = create(:company)
    # TimesheetEntry#company is read-only (it goes through two associations), so the company is set by column.
    entry = create(:timesheet_entry)
    entry.update_columns(company_id: company.id)

    before_digest = nil
    after_digest = nil
    ActiveRecord::Base.cache do
      before_digest = TenantStateDigest.monolith(company_id: company.id)
      ActiveRecord::Base.connection.raw_connection.exec_params(
        "UPDATE timesheet_entries SET bill_status = CASE WHEN bill_status = 0 THEN 1 ELSE 0 END WHERE id = $1",
        [entry.id]
      )
      after_digest = TenantStateDigest.monolith(company_id: company.id)
    end

    expect(after_digest.fetch(:projection)).not_to eq(before_digest.fetch(:projection))
  end
end


RSpec.describe "TenantStateDigest" do
  # "Hash the table name and each row with a length-prefixed separator, using `Digest::SHA256`."
  # Without a length-prefixed frame, a row moved from one table to the next, or one row split into
  # two, would feed the same bytes to the hash and hide the change.
  it "group_digest tells apart a row moved to the other table of the group and a row split in two" do
    row = '{"id":1,"company_id":7}'
    in_first = TenantStateDigest.group_digest([["idempotency_receipts", [row]], ["service_idempotency_receipts", []]])
    in_second = TenantStateDigest.group_digest([["idempotency_receipts", []], ["service_idempotency_receipts", [row]]])
    one_row = TenantStateDigest.group_digest([["entries", ["ab"]]])
    two_rows = TenantStateDigest.group_digest([["entries", %w[a b]]])

    expect(in_first).to match(/\A\h{64}\z/)
    expect(in_first).not_to eq(in_second)
    expect(one_row).not_to eq(two_rows)
  end
end

RSpec.describe "TenantStateDigest empty group literals" do
  # Written out by hand rather than recomputed through group_digest, so a change to the framing or to
  # a group's table list fails here instead of moving the expected value with it.
  pinned_empty_group_digests = {
    monolith: {
      projection: "ebf10c374d459d6297f061a05441601366ab40c96fdd62a58c03e7c959e9956c",
      entries: "0f408c1ec978a88e9d2ff359dc0e121014fc386f33cb507b7cc93172bb42f3fb",
      receipts: "97e16cb48ce14bd39e9e49eb38ecd3921743fc5be208e75b974c07ff70f541ef",
      outbox: "f4f74d1ce7f54c6fcf73626627229a1a33909bf5583a99516cf147902ca9ccac",
      invoice_operations: "5a9c45e6bb9806b5f44147096339b5acd720380b4228d4a7e2adee5dd06760e4"
    },
    timekeeping: {
      entries: "0f408c1ec978a88e9d2ff359dc0e121014fc386f33cb507b7cc93172bb42f3fb",
      receipts: "d073b2d2c3a58f067acbfd57f3f39ca9b5e98378359a04ee127a2594dc73f48f",
      outbox: "18fcb8fba70dee8a29763a3d23ed09763c375e64a44a2cccb7d039171fd9785d",
      invoice_operations: "5a9c45e6bb9806b5f44147096339b5acd720380b4228d4a7e2adee5dd06760e4"
    }
  }

  # "An empty group has a fixed, pinned digest."
  it "every group of each database with no rows digests to its pinned literal" do
    pinned_empty_group_digests.each do |database, groups|
      expect(TenantStateDigest::GROUPS.fetch(database).keys).to eq(groups.keys), database.to_s
      groups.each do |group, literal|
        empty_tables = TenantStateDigest::GROUPS.fetch(database).fetch(group).map { |spec| [spec.table, []] }
        expect(TenantStateDigest.group_digest(empty_tables)).to eq(literal), "#{database} #{group}"
      end
    end
  end

  it "a monolith company with no rows takes exactly the pinned literals" do
    expect(TenantStateDigest.monolith(company_id: 9_437_301)).to eq(pinned_empty_group_digests.fetch(:monolith))
  end

  it "a Timekeeping company with no rows takes exactly the pinned literals" do
    skip "set TIMEKEEPING_LIVE=1 to use the Timekeeping test database" unless ENV["TIMEKEEPING_LIVE"] == "1"

    url = ENV.fetch("TIMEKEEPING_DATABASE_URL")
    IntegratedRuntime.require_test_database_url!(url)
    output, status = Bundler.with_unbundled_env do
      Open3.capture2e({ "RAILS_ENV" => "test", "BUNDLE_GEMFILE" => Rails.root.join("timekeeping/Gemfile").to_s,
                        "TIMEKEEPING_DATABASE_URL" => url, "DATABASE_URL" => nil },
                      "bundle", "exec", "rails", "db:prepare", chdir: Rails.root.join("timekeeping").to_s)
    end
    raise "db:prepare failed:\n#{output}" unless status.success?

    expect(TenantStateDigest.timekeeping(company_id: 9_437_302, timekeeping_url: url))
      .to eq(pinned_empty_group_digests.fetch(:timekeeping))
  end
end

RSpec.describe "TenantStateDigest isolation for every monolith table in GROUPS" do
  # "For every group in each database, a row inserted for B leaves A's digest equal, and the reverse also holds."
  # The table list comes from GROUPS itself, so a table added there without a row writer here fails.
  it "a row inserted for one company in each monolith table moves that company's group digest and leaves the other's digest equal, both ways" do
    connection = ActiveRecord::Base.connection
    company_a = create(:company)
    company_b = create(:company)
    insert_entry_sql = "INSERT INTO entries (bill_status, company_id, created_at, updated_at, duration, project_id, " \
                       "user_id, work_date) VALUES ('unbilled', $1, now(), now(), 60, 1, 1, CURRENT_DATE)"
    row_writers = {
      "timesheet_entries" => lambda { |company_id|
        create(:timesheet_entry).update_columns(company_id:)
      },
      "entries" => ->(company_id) { connection.exec_query(insert_entry_sql, "digest", [company_id]) },
      "idempotency_records" => lambda { |company_id|
        connection.exec_query(
          "INSERT INTO idempotency_records (actor_id, actor_type, body, company_id, created_at, fingerprint, key, " \
          "operation, status) VALUES (1, 'user', '{}', $1, now(), 'digest', $2, 'create', 201)",
          "digest", [company_id, SecureRandom.uuid]
        )
      },
      "entry_snapshot_receipts" => lambda { |company_id|
        connection.exec_query(
          "INSERT INTO entry_snapshot_receipts (actor, company_ids, created_at, expires_at, key, request_digest, " \
          "response_status) VALUES ('digest-spec', ARRAY[$1]::bigint[], now(), now() + interval '1 day', $2, 'rd', 200)",
          "digest", [company_id, SecureRandom.uuid]
        )
      },
      "entry_outbox_items" => lambda { |company_id|
        connection.exec_query(
          "INSERT INTO entry_outbox_items (company_id, created_at, entry_id, generation, payload) " \
          "VALUES ($1, now(), 1, 1, '{}')",
          "digest", [company_id]
        )
      },
      "invoice_operations" => lambda { |company_id|
        connection.exec_query(
          "INSERT INTO invoice_operations (company_id, invoice_id, operation_id, actor_name, state, disposition, " \
          "generation, created_at) VALUES ($1, 77, gen_random_uuid(), 'monolith', 'committed', 'active', 1, now())",
          "digest", [company_id]
        )
      },
      # reservations needs an entries row of the same company for its foreign key.
      "reservations" => lambda { |company_id|
        connection.exec_query(
          "WITH entry AS (#{insert_entry_sql} RETURNING id, company_id) " \
          "INSERT INTO reservations (company_id, created_at, disposition, entry_id, invoice_id, operation_id, state) " \
          "SELECT company_id, now(), 'active', id, 77, gen_random_uuid(), 'provisional' FROM entry",
          "digest", [company_id]
        )
      }
    }
    tables_by_group = TenantStateDigest::GROUPS.fetch(:monolith).transform_values { |specs| specs.map(&:table) }
    expect(row_writers.keys).to match_array(tables_by_group.values.flatten)

    [[company_b.id, company_a.id], [company_a.id, company_b.id]].each do |writer, other|
      tables_by_group.each do |group, tables|
        tables.each do |table|
          writer_before = TenantStateDigest.monolith(company_id: writer)
          other_before = TenantStateDigest.monolith(company_id: other)

          row_writers.fetch(table).call(writer)

          expect(TenantStateDigest.monolith(company_id: writer).fetch(group))
            .not_to eq(writer_before.fetch(group)), "#{table} for #{writer}"
          expect(TenantStateDigest.monolith(company_id: other)).to eq(other_before), "#{table} for #{writer}"
        end
      end
    end
  end
end

RSpec.describe "TenantStateDigest isolation for every Timekeeping table in GROUPS", :without_transaction do
  # "For every group in each database, a row inserted for B leaves A's digest equal, and the reverse also holds."
  it "a row inserted for one company in each Timekeeping table moves that company's group digest and leaves the other's digest equal, both ways" do
    skip "set TIMEKEEPING_LIVE=1 to use the Timekeeping test database" unless ENV["TIMEKEEPING_LIVE"] == "1"

    url = ENV.fetch("TIMEKEEPING_DATABASE_URL")
    IntegratedRuntime.require_test_database_url!(url)
    output, status = Bundler.with_unbundled_env do
      Open3.capture2e({ "RAILS_ENV" => "test", "BUNDLE_GEMFILE" => Rails.root.join("timekeeping/Gemfile").to_s,
                        "TIMEKEEPING_DATABASE_URL" => url, "DATABASE_URL" => nil },
                      "bundle", "exec", "rails", "db:prepare", chdir: Rails.root.join("timekeeping").to_s)
    end
    raise "db:prepare failed:\n#{output}" unless status.success?

    company_a = 9_437_401
    company_b = 9_437_402
    connection = PG.connect(url)
    insert_entry_sql = "INSERT INTO entries (company_id, project_id, user_id, work_date, duration, bill_status, " \
                       "created_at, updated_at) VALUES ($1, 1, 1, CURRENT_DATE, 60, 'unbilled', now(), now())"
    row_writers = {
      "entries" => ->(company_id) { connection.exec_params(insert_entry_sql, [company_id]) },
      "idempotency_receipts" => lambda { |company_id|
        connection.exec_params(
          "INSERT INTO idempotency_receipts (company_id, actor_type, actor_id, operation, key, fingerprint, status, " \
          "body, created_at) VALUES ($1, 'user', 1, 'create', $2, 'digest', 201, '{}', now())",
          [company_id, SecureRandom.uuid]
        )
      },
      "service_idempotency_receipts" => lambda { |company_id|
        connection.exec_params(
          "INSERT INTO service_idempotency_receipts (company_id, actor_name, operation, key, fingerprint, status, " \
          "body, created_at) VALUES ($1, 'monolith', 'prepare', $2, 'digest', 200, '{}', now())",
          [company_id, SecureRandom.uuid]
        )
      },
      "outbox_snapshots" => lambda { |company_id|
        connection.exec_params(
          "INSERT INTO outbox_snapshots (id, project_id, user_id, work_date, duration, bill_status, review_status, " \
          "locked, source, source_metadata, proof_metadata, created_at, updated_at, company_id, version, generation) " \
          "VALUES (1, 1, 1, CURRENT_DATE, 60, 'unbilled', 'not_required', false, 'manual', '{}', '{}', now(), now(), " \
          "$1, 1, 1)",
          [company_id]
        )
      },
      "invoice_operations" => lambda { |company_id|
        connection.exec_params(
          "INSERT INTO invoice_operations (company_id, invoice_id, operation_id, actor_name, state, disposition, " \
          "generation, created_at) VALUES ($1, 77, gen_random_uuid(), 'monolith', 'committed', 'active', 1, now())",
          [company_id]
        )
      },
      # reservations needs an entries row of the same company for its foreign key.
      "reservations" => lambda { |company_id|
        connection.exec_params(
          "WITH entry AS (#{insert_entry_sql} RETURNING id, company_id) " \
          "INSERT INTO reservations (company_id, entry_id, invoice_id, state, disposition, operation_id, created_at) " \
          "SELECT company_id, id, 77, 'provisional', 'active', gen_random_uuid(), now() FROM entry",
          [company_id]
        )
      }
    }
    tables_by_group = TenantStateDigest::GROUPS.fetch(:timekeeping).transform_values { |specs| specs.map(&:table) }
    expect(row_writers.keys).to match_array(tables_by_group.values.flatten)
    digest = ->(company_id) { TenantStateDigest.timekeeping(company_id:, timekeeping_url: url) }

    [[company_b, company_a], [company_a, company_b]].each do |writer, other|
      tables_by_group.each do |group, tables|
        tables.each do |table|
          writer_before = digest.call(writer)
          other_before = digest.call(other)

          row_writers.fetch(table).call(writer)

          expect(digest.call(writer).fetch(group)).not_to eq(writer_before.fetch(group)), "#{table} for #{writer}"
          expect(digest.call(other)).to eq(other_before), "#{table} for #{writer}"
        end
      end
    end
  ensure
    if connection
      [company_a, company_b].each do |id|
        %w[reservations invoice_operations outbox_snapshots service_idempotency_receipts idempotency_receipts
           entries].each do |table|
          connection.exec_params("DELETE FROM #{connection.quote_ident(table)} WHERE company_id = $1", [id])
        end
      end
      connection.close
    end
  end
end
