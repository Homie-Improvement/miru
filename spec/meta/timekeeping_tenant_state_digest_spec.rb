# frozen_string_literal: true

require "rails_helper"
require "open3"
require "pg"
require "securerandom"

RSpec.describe TenantStateDigest do
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
  sha256_of_nothing = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  monolith_entry_sql = "INSERT INTO entries (bill_status, company_id, created_at, updated_at, duration, project_id, " \
                       "user_id, work_date) VALUES ('unbilled', $1, now(), now(), 60, 1, 1, CURRENT_DATE)"
  timekeeping_entry_sql = "INSERT INTO entries (company_id, project_id, user_id, work_date, duration, bill_status, " \
                          "created_at, updated_at) VALUES ($1, 1, 1, CURRENT_DATE, 60, 'unbilled', now(), now())"
  timekeeping_tables = %w[reservations invoice_operations outbox_snapshots service_idempotency_receipts
                          idempotency_receipts entries].freeze

  def insert_digest_monolith_entry(sql, company_id)
    ActiveRecord::Base.connection.select_value("#{sql} RETURNING id", "digest", [company_id])
  end

  # Skips unless TIMEKEEPING_LIVE=1, checks the URL names a _test database, then prepares its schema.
  def prepare_digest_timekeeping_database
    skip "set TIMEKEEPING_LIVE=1 to use the Timekeeping test database" unless ENV["TIMEKEEPING_LIVE"] == "1"

    url = ENV.fetch("TIMEKEEPING_DATABASE_URL")
    IntegratedRuntime.require_test_database_url!(url)
    output, status = Bundler.with_unbundled_env do
      Open3.capture2e({ "RAILS_ENV" => "test", "BUNDLE_GEMFILE" => Rails.root.join("timekeeping/Gemfile").to_s,
                        "TIMEKEEPING_DATABASE_URL" => url, "DATABASE_URL" => nil },
                      "bundle", "exec", "rails", "db:prepare", chdir: Rails.root.join("timekeeping").to_s)
    end
    raise "db:prepare failed:\n#{output}" unless status.success?

    url
  end

  def delete_digest_timekeeping_rows(connection, tables, company_ids)
    company_ids.each do |id|
      tables.each do |table|
        connection.exec_params("DELETE FROM #{connection.quote_ident(table)} WHERE company_id = $1", [id])
      end
    end
  end

  describe "refusal before connecting" do
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

          expect { described_class.take(company_id: 1, timekeeping_url: conninfo) }
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

    # libpq reads the dbname parameter and Active Record reads the path, so both must name a _test
    # database: a check of either reading alone would let one of these URLs through.
    it "take refuses a URL whose path and dbname parameter disagree on a _test name, in both directions, before connecting and without the URL" do
      user = "digest_mixed_user"
      password = "digest-mixed-secret-9a2e"
      host = "db.invalid"
      base = "postgres://#{user}:#{password}@#{host}:5432"
      urls = [
        ["timekeeping_demo", "#{base}/timekeeping_test?dbname=timekeeping_demo"],
        ["timekeeping_live", "#{base}/timekeeping_live?dbname=timekeeping_test"],
        ["timekeeping_demo", "#{base}/timekeeping_demo?dbname=timekeeping_test"]
      ]

      urls.each do |refused_name, url|
        expect { described_class.take(company_id: 1, timekeeping_url: url) }
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

    it "the Timekeeping-only digest refuses a non-test database name before connecting, naming only the database" do
      user = "digest_side_user"
      password = "digest-side-secret-5f07"
      host = "db.invalid"
      url = "postgres://#{user}:#{password}@#{host}:5432/timekeeping_development"

      expect { described_class.timekeeping(company_id: 1, timekeeping_url: url) }
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

  describe "connection failures" do
    # That connect replaces the driver's error, which can carry the host, with one naming only the database.
    it "take raises a connection error naming only the database when a _test Timekeeping database cannot be reached" do
      user = "digest_unreachable_user"
      password = "digest-unreachable-secret-c3d8"
      url = "postgres://#{user}:#{password}@127.0.0.1:1/timekeeping_unreachable_test"

      expect { described_class.take(company_id: 1, timekeeping_url: url) }
        .to raise_error(PG::ConnectionBad) { |error|
          expect(error.message).to include("timekeeping_unreachable_test")
          expect(error.message).not_to include(password)
          expect(error.message).not_to include(user)
          expect(error.message).not_to include("127.0.0.1")
          expect(error.message).not_to include(url)
          expect(error.cause).to be_nil
        }
    end

    # A database that cannot be read must never digest as empty: equal before and after values would
    # then claim a request changed nothing when nothing was read.
    it "timekeeping raises naming only the database when a _test database cannot be reached, and returns no digest" do
      password = "digest-unreachable-secret-3f2"
      url = "host=127.0.0.1 port=1 user=digest_unreachable_user password=#{password} dbname=timekeeping_digest_unreachable_test"

      expect { described_class.timekeeping(company_id: 990_103, timekeeping_url: url) }
        .to raise_error(PG::ConnectionBad) { |error|
          expect(error.message).to include("timekeeping_digest_unreachable_test")
          expect(error.message).not_to include(password)
          expect(error.message).not_to include("127.0.0.1")
          expect(error.message).not_to include("digest_unreachable_user")
          expect(error.cause).to be_nil
        }
    end
  end

  describe "GROUPS" do
    it "lists exactly the tables the issue names for each group in each database" do
      tables = described_class::GROUPS.transform_values do |groups|
        groups.transform_values { |specs| specs.map { |spec| spec.table.to_s } }
      end

      expect(described_class::GROUPS).to be_frozen
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

  describe ".group_digest" do
    it "keeps a NULL column distinct from an empty string in row_to_json text" do
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

    it "of no tables is the pinned SHA-256 of nothing and an empty table group is a fixed value that one row moves" do
      # Pinned literal: SHA-256 over zero bytes, which is what a group with no frames hashes.
      expect(described_class.group_digest([])).to eq(sha256_of_nothing)

      # "An empty group digests to a fixed value, and a single inserted row changes it."
      empty_group = [["invoice_operations", []], ["reservations", []]]
      empty_value = described_class.group_digest(empty_group)
      expect(empty_value).to match(/\A\h{64}\z/)
      expect(described_class.group_digest(empty_group.map { |table, rows| [table.dup, rows.dup] })).to eq(empty_value)
      expect(empty_value).not_to eq(sha256_of_nothing)

      one_row = [["invoice_operations", ['{"id":1,"company_id":7}']], ["reservations", []]]
      expect(described_class.group_digest(one_row)).not_to eq(empty_value)

      # The table name is part of the hash, so the same rows under another table name differ.
      renamed = [["invoice_operations", []], ["reservation", []]]
      expect(described_class.group_digest(renamed)).not_to eq(empty_value)
    end

    # "Hash the table name and each row with a length-prefixed separator, using `Digest::SHA256`."
    # Without a length-prefixed frame, a row moved from one table to the next, or one row split into
    # two, would feed the same bytes to the hash and hide the change.
    it "tells apart a row moved to the other table of the group and a row split in two" do
      row = '{"id":1,"company_id":7}'
      in_first = described_class.group_digest([["idempotency_receipts", [row]], ["service_idempotency_receipts", []]])
      in_second = described_class.group_digest([["idempotency_receipts", []], ["service_idempotency_receipts", [row]]])
      one_row = described_class.group_digest([["entries", ["ab"]]])
      two_rows = described_class.group_digest([["entries", %w[a b]]])

      expect(in_first).to match(/\A\h{64}\z/)
      expect(in_first).not_to eq(in_second)
      expect(one_row).not_to eq(two_rows)
    end
  end

  describe "empty group literals" do
    # "An empty group has a fixed, pinned digest."
    it "every group of each database with no rows digests to its pinned literal" do
      pinned_empty_group_digests.each do |database, groups|
        expect(described_class::GROUPS.fetch(database).keys).to eq(groups.keys), database.to_s
        groups.each do |group, literal|
          empty_tables = described_class::GROUPS.fetch(database).fetch(group).map { |spec| [spec.table, []] }
          expect(described_class.group_digest(empty_tables)).to eq(literal), "#{database} #{group}"
        end
      end
    end

    # "An empty group digests to a fixed value, and a single inserted row changes it."
    it "a monolith company with no rows takes exactly the pinned literals, and a single inserted row changes only that group" do
      empty_company = 9_437_301
      other_empty_company = 9_437_302
      expect(described_class.monolith(company_id: empty_company)).to eq(pinned_empty_group_digests.fetch(:monolith))
      expect(described_class.monolith(company_id: other_empty_company)).to eq(pinned_empty_group_digests.fetch(:monolith))

      insert_digest_monolith_entry(monolith_entry_sql, empty_company)
      after = described_class.monolith(company_id: empty_company)

      expect(after.fetch(:entries)).not_to eq(pinned_empty_group_digests.fetch(:monolith).fetch(:entries))
      expect(after.except(:entries)).to eq(pinned_empty_group_digests.fetch(:monolith).except(:entries))
      expect(described_class.monolith(company_id: other_empty_company)).to eq(pinned_empty_group_digests.fetch(:monolith))
    end

    it "a Timekeeping company with no rows takes exactly the pinned literals, the same for any empty company" do
      url = prepare_digest_timekeeping_database

      [9_437_302, 9_437_303].each do |company_id|
        expect(described_class.timekeeping(company_id:, timekeeping_url: url))
          .to eq(pinned_empty_group_digests.fetch(:timekeeping)), company_id.to_s
      end
    end
  end

  describe "monolith" do
    # "A `bill_status` flip on one company changes only that company's monolith digest."
    it "a bill_status flip on one company's timesheet entry changes only that company's projection digest" do
      company_a = create(:company)
      company_b = create(:company)
      # TimesheetEntry#company is read-only (it goes through two associations), so the company is set by column.
      entry_a = create(:timesheet_entry)
      entry_a.update_columns(company_id: company_a.id)
      create(:timesheet_entry).update_columns(company_id: company_b.id)
      empty_projection = pinned_empty_group_digests.fetch(:monolith).fetch(:projection)

      before_a = described_class.monolith(company_id: company_a.id)
      before_b = described_class.monolith(company_id: company_b.id)
      expect(before_a.fetch(:projection)).not_to eq(empty_projection)
      expect(before_b.fetch(:projection)).not_to eq(empty_projection)

      ActiveRecord::Base.connection.exec_query(
        "UPDATE timesheet_entries SET bill_status = CASE WHEN bill_status = 0 THEN 1 ELSE 0 END WHERE id = $1",
        "digest", [entry_a.id]
      )

      expect(described_class.monolith(company_id: company_a.id).fetch(:projection)).not_to eq(before_a.fetch(:projection))
      expect(described_class.monolith(company_id: company_b.id)).to eq(before_b)
    end

    # A write through the raw connection does not clear Active Record's query cache, so a digest that
    # reused a cached result would report no change for a real write.
    it "sees a bill_status flip made inside an Active Record query cache through the raw connection" do
      company = create(:company)
      entry = create(:timesheet_entry)
      entry.update_columns(company_id: company.id)

      before_digest = nil
      after_digest = nil
      ActiveRecord::Base.cache do
        before_digest = described_class.monolith(company_id: company.id)
        ActiveRecord::Base.connection.raw_connection.exec_params(
          "UPDATE timesheet_entries SET bill_status = CASE WHEN bill_status = 0 THEN 1 ELSE 0 END WHERE id = $1",
          [entry.id]
        )
        after_digest = described_class.monolith(company_id: company.id)
      end

      expect(after_digest.fetch(:projection)).not_to eq(before_digest.fetch(:projection))
    end

    # "Changing a value from NULL to an empty string changes the digest."
    it "changes for the company whose entries row goes from NULL to empty proof_url and stays equal for another company" do
      company_a = 990_201
      company_b = 990_202
      entry_a = insert_digest_monolith_entry(monolith_entry_sql, company_a)
      insert_digest_monolith_entry(monolith_entry_sql, company_b)
      empty_entries = pinned_empty_group_digests.fetch(:monolith).fetch(:entries)

      before_a = described_class.monolith(company_id: company_a)
      before_b = described_class.monolith(company_id: company_b)
      expect(before_a.fetch(:entries)).not_to eq(empty_entries)
      expect(before_b.fetch(:entries)).not_to eq(empty_entries)

      ActiveRecord::Base.connection.exec_query("UPDATE entries SET proof_url = '' WHERE id = $1", "digest", [entry_a])

      expect(described_class.monolith(company_id: company_a).fetch(:entries)).not_to eq(before_a.fetch(:entries))
      expect(described_class.monolith(company_id: company_b)).to eq(before_b)
    end

    # "Two takes with no write in between are equal, `reservations` rows included."
    it "is equal across two takes with reservations rows present and moves only for the company whose reservation is added" do
      company_a = 990_501
      company_b = 990_502
      connection = ActiveRecord::Base.connection
      add_reservation = lambda do |company_id, invoice_id|
        entry_id = insert_digest_monolith_entry(monolith_entry_sql, company_id)
        connection.exec_query(
          "INSERT INTO reservations (company_id, created_at, disposition, entry_id, invoice_id, operation_id, state) " \
          "VALUES ($1, now(), 'active', $2, $3, gen_random_uuid(), 'provisional')",
          "digest", [company_id, entry_id, invoice_id]
        )
      end
      add_reservation.call(company_a, 1)
      add_reservation.call(company_b, 2)
      expect(connection.select_value("SELECT count(*) FROM reservations WHERE company_id = #{company_a}").to_i).to eq(1)

      first = described_class.monolith(company_id: company_a)
      expect(described_class.monolith(company_id: company_a)).to eq(first)
      expect(first.fetch(:invoice_operations)).not_to eq(pinned_empty_group_digests.fetch(:monolith).fetch(:invoice_operations))

      b_before = described_class.monolith(company_id: company_b)
      add_reservation.call(company_b, 3)

      expect(described_class.monolith(company_id: company_b).fetch(:invoice_operations))
        .not_to eq(b_before.fetch(:invoice_operations))
      expect(described_class.monolith(company_id: company_a)).to eq(first)
    end

    # "For every group in each database, a row inserted for B leaves A's digest equal, and the reverse also holds."
    # The table list comes from GROUPS itself, so a table added there without a row writer here fails.
    # The snapshot receipt lists only the writer: a receipt listing both companies belongs to both digests.
    it "a row inserted for one company in each monolith table moves that company's group digest and leaves the other's digest equal, both ways" do
      connection = ActiveRecord::Base.connection
      company_a = create(:company)
      company_b = create(:company)
      row_writers = {
        "timesheet_entries" => lambda { |company_id|
          create(:timesheet_entry).update_columns(company_id:)
        },
        "entries" => ->(company_id) { connection.exec_query(monolith_entry_sql, "digest", [company_id]) },
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
            "WITH entry AS (#{monolith_entry_sql} RETURNING id, company_id) " \
            "INSERT INTO reservations (company_id, created_at, disposition, entry_id, invoice_id, operation_id, state) " \
            "SELECT company_id, now(), 'active', id, 77, gen_random_uuid(), 'provisional' FROM entry",
            "digest", [company_id]
          )
        }
      }
      tables_by_group = described_class::GROUPS.fetch(:monolith).transform_values { |specs| specs.map(&:table) }
      expect(row_writers.keys).to match_array(tables_by_group.values.flatten)

      [[company_b.id, company_a.id], [company_a.id, company_b.id]].each do |writer, other|
        tables_by_group.each do |group, tables|
          tables.each do |table|
            writer_before = described_class.monolith(company_id: writer)
            other_before = described_class.monolith(company_id: other)

            row_writers.fetch(table).call(writer)

            expect(described_class.monolith(company_id: writer).fetch(group))
              .not_to eq(writer_before.fetch(group)), "#{table} for #{writer}"
            expect(described_class.monolith(company_id: other)).to eq(other_before), "#{table} for #{writer}"
          end
        end
      end
    end
  end

  describe "on the live Timekeeping database" do
    it "take moves only B's Timekeeping digest for an entries or service_idempotency_receipts row for B" do
      url = prepare_digest_timekeeping_database
      company_a = 990_701
      company_b = 990_702
      connection = PG.connect(url)
      begin
        connection.exec_params(timekeeping_entry_sql, [company_a])
        before_a = described_class.take(company_id: company_a, timekeeping_url: url)
        before_b = described_class.take(company_id: company_b, timekeeping_url: url)
        expect(before_a.keys).to contain_exactly(:monolith, :timekeeping)
        expect(before_a.fetch(:timekeeping).fetch(:entries)).not_to eq(before_b.fetch(:timekeeping).fetch(:entries))

        # "A Timekeeping row, or a `service_idempotency_receipts` row, for B changes only B's Timekeeping digest."
        connection.exec_params(timekeeping_entry_sql, [company_b])
        after_entry_b = described_class.take(company_id: company_b, timekeeping_url: url)
        expect(after_entry_b.fetch(:timekeeping).fetch(:entries)).not_to eq(before_b.fetch(:timekeeping).fetch(:entries))
        expect(described_class.take(company_id: company_a, timekeeping_url: url)).to eq(before_a)

        connection.exec_params(
          "INSERT INTO service_idempotency_receipts (company_id, actor_name, operation, key, fingerprint, status, body, created_at) " \
          "VALUES ($1, 'digest-spec', 'create', 'digest-spec-key', 'digest', 200, '{}', now())", [company_b]
        )
        after_receipt_b = described_class.take(company_id: company_b, timekeeping_url: url)
        expect(after_receipt_b.fetch(:timekeeping).fetch(:receipts)).not_to eq(after_entry_b.fetch(:timekeeping).fetch(:receipts))
        expect(described_class.take(company_id: company_a, timekeeping_url: url)).to eq(before_a)
        expect(described_class.take(company_id: company_b, timekeeping_url: url)).to eq(after_receipt_b)
      ensure
        delete_digest_timekeeping_rows(connection, timekeeping_tables, [company_a, company_b])
        connection.close
      end
    end

    # "For every group in each database, a row inserted for B leaves A's digest equal, and the reverse also holds."
    # "Two takes with no write in between are equal, `reservations` rows included."
    it "a row inserted for one company in each Timekeeping table moves that company's group digest and leaves the other's digest equal, both ways, and two takes are then equal", :without_transaction do
      url = prepare_digest_timekeeping_database
      company_a = 9_437_401
      company_b = 9_437_402
      connection = PG.connect(url)
      row_writers = {
        "entries" => ->(company_id) { connection.exec_params(timekeeping_entry_sql, [company_id]) },
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
            "WITH entry AS (#{timekeeping_entry_sql} RETURNING id, company_id) " \
            "INSERT INTO reservations (company_id, entry_id, invoice_id, state, disposition, operation_id, created_at) " \
            "SELECT company_id, id, 77, 'provisional', 'active', gen_random_uuid(), now() FROM entry",
            [company_id]
          )
        }
      }
      tables_by_group = described_class::GROUPS.fetch(:timekeeping).transform_values { |specs| specs.map(&:table) }
      expect(row_writers.keys).to match_array(tables_by_group.values.flatten)
      digest = ->(company_id) { described_class.timekeeping(company_id:, timekeeping_url: url) }

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

      expect(connection.exec_params("SELECT count(*) FROM reservations WHERE company_id = $1", [company_a]).getvalue(0, 0).to_i)
        .to be >= 1
      expect(digest.call(company_a)).to eq(digest.call(company_a))
    ensure
      if connection
        delete_digest_timekeeping_rows(connection, timekeeping_tables, [company_a, company_b])
        connection.close
      end
    end
  end
end
