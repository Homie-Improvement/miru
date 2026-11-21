# frozen_string_literal: true

require "rails_helper"
require "pg"
require "securerandom"

RSpec.describe LiveHandoff do
  it "web_replay_request carries only the replaying company's X-Auth credentials and drops the recorded Authorization header" do
    a_token = "company-a-token-7f3c"
    a_bearer = "Bearer company-a-cli-9d21"
    recorded = {
      method: "POST",
      path: "/api/v1/timesheet_entry",
      headers: {
        "Idempotency-Key" => "replay-key-1",
        "X-Auth-Email" => "owner-a@example.test",
        "X-Auth-Token" => a_token,
        "Authorization" => a_bearer
      },
      body: { "project_id" => 11, "timesheet_entry" => { "duration" => 60, "note" => "a note" } }
    }
    original = Marshal.load(Marshal.dump(recorded))

    replay = described_class.web_replay_request(
      recorded, company_id: 2, auth_email: "owner-b@example.test", auth_token: "company-b-token-1a2b"
    )

    # "It keeps the recorded path, Idempotency-Key and body, and replaces the `X-Auth-Email` and `X-Auth-Token` headers."
    expect(replay.fetch(:path)).to eq("/api/v1/timesheet_entry")
    expect(replay.fetch(:body)).to eq(original.fetch(:body))
    expect(replay.fetch(:headers).fetch("Idempotency-Key")).to eq("replay-key-1")
    expect(replay.fetch(:headers).fetch("X-Auth-Email")).to eq("owner-b@example.test")
    expect(replay.fetch(:headers).fetch("X-Auth-Token")).to eq("company-b-token-1a2b")
    # The monolith authenticates a Bearer Authorization header before X-Auth, so a
    # leftover recorded header would sign the replay in as company A.
    expect(replay.fetch(:headers)).not_to have_key("Authorization")
    expect(replay.fetch(:headers).values).not_to include(a_token, a_bearer, "owner-a@example.test")
    expect(recorded).to eq(original)
  end
end


RSpec.describe LiveHandoff do
  it "timekeeping_counts refuses a database whose name does not end in _test before connecting, without credentials in the error" do
    allow(PG).to receive(:connect).and_call_original
    user = "live_handoff_guard_user"
    password = "live-handoff-guard-secret-5e8a"
    host = "db.invalid"
    url = "postgres://#{user}:#{password}@#{host}:5432/timekeeping_demo"

    # "Guard databases with `TestDatabaseGuard.require_test_database_url!`, and open Timekeeping SQL through ENV key `TimekeepingDatabaseReset::DATABASE_URL_KEY`. Never print credentials."
    expect { described_class.timekeeping_counts(company_id: 1, env: { TimekeepingDatabaseReset::DATABASE_URL_KEY => url }) }
      .to raise_error(TestDatabaseGuard::NotATestDatabase) { |error|
        expect(error.message).to include("timekeeping_demo")
        expect(error.message).not_to include(password)
        expect(error.message).not_to include(user)
        expect(error.message).not_to include(host)
      }
    expect(PG).not_to have_received(:connect)
  end
end


RSpec.describe LiveHandoff do
  it "replay_verdict never counts an unauthenticated or forbidden reply as a refusal in any table" do
    tables = [
      described_class::TIMEKEEPING_REFUSALS, described_class::MONOLITH_REFUSALS, described_class::CROSS_COMPANY_REFUSALS
    ]
    replies = [
      [401, { reason: "unauthorized" }.to_json],
      [401, { error: I18n.t("devise.failure.unauthenticated") }.to_json],
      [403, { errors: I18n.t("pundit.default") }.to_json]
    ]

    # "a 500 or any other body fails"
    tables.each do |refusals|
      replies.each do |status, body|
        verdict = described_class.replay_verdict(status:, body:, expected_body: "{}", refusals:)
        expect(verdict).to eq(:failed), "#{status} #{body}"
      end
    end
  end
end


RSpec.describe LiveHandoff do
  it "monolith_counts returns exact per-company values and each write for company A moves only A's matching counts" do
    connection = ActiveRecord::Base.connection
    company_a = create(:company).id
    company_b = create(:company).id

    insert_entry = lambda do |company_id, version|
      connection.select_value(
        "INSERT INTO entries (bill_status, company_id, created_at, updated_at, duration, project_id, user_id, " \
        "work_date, version) VALUES ('unbilled', $1, now(), now(), 60, 1, 1, CURRENT_DATE, $2) RETURNING id",
        "live_handoff_counts", [company_id, version]
      )
    end
    insert_projection_row = ->(company_id) { create(:timesheet_entry).update_columns(company_id:) }
    insert_audit = lambda do |company_id, auditable_type = "TimesheetEntry"|
      connection.exec_query(
        "INSERT INTO audits (auditable_type, auditable_id, associated_type, associated_id, action, version, created_at) " \
        "VALUES ($1, 1, 'Company', $2, 'update', 1, now())",
        "live_handoff_counts", [auditable_type, company_id]
      )
    end
    # entry_audits has a foreign key to entries on (company_id, entry_id), so each audit names an entry of its company.
    insert_entry_audit = lambda do |company_id, entry_id|
      connection.exec_query(
        "INSERT INTO entry_audits (action, actor_type, actor_id, after, company_id, created_at, entry_created_at, " \
        "entry_id) VALUES ('create', 'user', 1, '{}', $1, now(), now(), $2)",
        "live_handoff_counts", [company_id, entry_id]
      )
    end
    insert_legacy_receipt = lambda do |company_id|
      connection.exec_query(
        "INSERT INTO legacy_create_receipts (company_id, actor_kind, actor_id, key, fingerprint, timesheet_entry_id, " \
        "entry_attributes, created_at, expires_at) VALUES ($1, 'user', 1, $2, 'fp', 1, '{}', now(), " \
        "now() + interval '1 day')",
        "live_handoff_counts", [company_id, SecureRandom.uuid]
      )
    end
    insert_idempotency_record = lambda do |company_id|
      connection.exec_query(
        "INSERT INTO idempotency_records (actor_id, actor_type, body, company_id, created_at, fingerprint, key, " \
        "operation, status) VALUES (1, 'user', '{}', $1, now(), 'fp', $2, 'create', 201)",
        "live_handoff_counts", [company_id, SecureRandom.uuid]
      )
    end
    insert_snapshot_receipt = lambda do |company_id|
      connection.exec_query(
        "INSERT INTO entry_snapshot_receipts (actor, company_ids, created_at, expires_at, key, request_digest, " \
        "response_status) VALUES ('live-handoff-spec', ARRAY[$1]::bigint[], now(), now() + interval '1 day', $2, " \
        "'rd', 200)",
        "live_handoff_counts", [company_id, SecureRandom.uuid]
      )
    end
    insert_outbox_item = lambda do |company_id|
      connection.exec_query(
        "INSERT INTO entry_outbox_items (company_id, created_at, entry_id, generation, payload) " \
        "VALUES ($1, now(), 1, 1, '{}')",
        "live_handoff_counts", [company_id]
      )
    end
    seed_rows = lambda do |company_id, rows_per_table, entry_version|
      rows_per_table.times do
        entry_id = insert_entry.call(company_id, entry_version)
        insert_projection_row.call(company_id)
        insert_audit.call(company_id)
        insert_entry_audit.call(company_id, entry_id)
        insert_legacy_receipt.call(company_id)
        insert_idempotency_record.call(company_id)
        insert_snapshot_receipt.call(company_id)
        insert_outbox_item.call(company_id)
      end
    end

    # Distinguishable seeds: two rows per table for A with entry version 3, one row per table for B with version 1.
    seed_rows.call(company_a, 2, 3)
    seed_rows.call(company_b, 1, 1)
    # An audit of another model, associated with A, must not count as a TimesheetEntry audit of A.
    insert_audit.call(company_a, "Invoice")

    # "Every query filters by that one company id (or its `company_ids` list); counts of two companies are never added together."
    a_counts = described_class.monolith_counts(company_id: company_a)
    b_counts = described_class.monolith_counts(company_id: company_b)
    # Nine monolith counts: eight row counts of 2 for A, and A's version sum 2 * 3 = 6.
    expect(a_counts.size).to eq(9)
    expect(a_counts.values.sort).to eq([2, 2, 2, 2, 2, 2, 2, 2, 6])
    expect(b_counts.values).to eq([1] * 9)

    changed_amounts = lambda do |before, after|
      expect(after.keys).to match_array(before.keys)
      before.keys.filter_map { |key| after.fetch(key) - before.fetch(key) unless after.fetch(key) == before.fetch(key) }.sort
    end

    # "adding an entry, raising one entry's version, adding an audit row and adding a receipt for company A changes
    # exactly the matching counts of A and leaves every count of company B unchanged."
    writes = {
      "an entry" => [-> { insert_entry.call(company_a, 1) }, [1, 1]],
      "a raised version" => [-> { connection.exec_query("UPDATE entries SET version = version + 1 WHERE id = (SELECT min(id) FROM entries WHERE company_id = $1)", "live_handoff_counts", [company_a]) }, [1]],
      "an audit row" => [-> { insert_audit.call(company_a) }, [1]],
      "a receipt" => [-> { insert_legacy_receipt.call(company_a) }, [1]]
    }
    writes.each do |label, (write, expected_changes)|
      a_before = described_class.monolith_counts(company_id: company_a)
      write.call
      expect(changed_amounts.call(a_before, described_class.monolith_counts(company_id: company_a))).to eq(expected_changes), label
      expect(described_class.monolith_counts(company_id: company_b)).to eq(b_counts), label
    end
  end
end


RSpec.describe LiveHandoff do
  context "live Timekeeping counts for two companies", :integrated_runtime, committed_data: true do
    it "timekeeping_counts and tenant_counts keep two companies apart in the live Timekeeping database" do
      company_a = 970_001
      company_b = 970_002
      url = ENV.fetch(TimekeepingDatabaseReset::DATABASE_URL_KEY)
      TestDatabaseGuard.require_test_database_url!(url)
      connection = TimekeepingDatabaseReset.connect(url, TimekeepingDatabaseReset.database_name(url))
      add_entry = lambda do |company_id, version|
        connection.exec_params(
          "INSERT INTO entries (company_id, version, project_id, user_id, work_date, duration, bill_status, " \
          "created_at, updated_at) VALUES ($1, $2, 1, 1, CURRENT_DATE, 60, 'unbilled', now(), now()) RETURNING id",
          [company_id, version]
        ).getvalue(0, 0).to_i
      end
      add_audit = lambda do |company_id, entry_id|
        connection.exec_params(
          "INSERT INTO audit_events (company_id, entry_id, actor_type, actor_id, action, after, entry_created_at, " \
          "created_at) VALUES ($1, $2, 'user', 1, 'create', '{}', now(), now())", [company_id, entry_id]
        )
      end
      # Distinguishable seeds: A has one entry at version 2, B has three entries and two audit rows.
      a_entry = add_entry.call(company_a, 2)
      b_entries = Array.new(3) { add_entry.call(company_b, 1) }
      b_entries.first(2).each { |id| add_audit.call(company_b, id) }

      a_before = described_class.timekeeping_counts(company_id: company_a)
      b_before = described_class.timekeeping_counts(company_id: company_b)
      expect(a_before).not_to eq(b_before)
      expect(a_before.values.sort).to eq([0, 0, 0, 0, 1, 2])
      expect(b_before.values.sort).to eq([0, 0, 0, 2, 3, 3])
      expect(described_class.tenant_counts(company_id: company_a).fetch(:timekeeping)).to eq(a_before)

      changed_by = lambda do |before, after|
        after.to_h { |key, value| [key, value - before.fetch(key)] }.reject { |_key, delta| delta.zero? }.values.sort
      end

      add_entry.call(company_a, 1)
      a_after_entry = described_class.timekeeping_counts(company_id: company_a)
      expect(changed_by.call(a_before, a_after_entry)).to eq([1, 1])

      connection.exec_params("UPDATE entries SET version = version + 4 WHERE id = $1", [a_entry])
      a_after_version = described_class.timekeeping_counts(company_id: company_a)
      expect(changed_by.call(a_after_entry, a_after_version)).to eq([4])

      add_audit.call(company_a, a_entry)
      a_after_audit = described_class.timekeeping_counts(company_id: company_a)
      expect(changed_by.call(a_after_version, a_after_audit)).to eq([1])

      expect(described_class.timekeeping_counts(company_id: company_b)).to eq(b_before)
    ensure
      if connection
        [company_a, company_b].each do |id|
          %w[audit_events entries].each do |table|
            connection.exec_params("DELETE FROM #{connection.quote_ident(table)} WHERE company_id = $1", [id])
          end
        end
        connection.close
      end
    end
  end
end


RSpec.describe LiveHandoff do
  # "Every query filters by that one company id (or its `company_ids` list); counts of two companies are never added together."
  it "monolith_counts returns only zeros for a company whose rows all belong to another company" do
    company_a = 910_001
    company_b = 910_002
    connection = ActiveRecord::Base.connection
    entry_id = connection.select_value(<<~SQL.squish)
      INSERT INTO entries (company_id, version, project_id, user_id, work_date, duration, bill_status, created_at, updated_at)
      VALUES (#{company_b}, 4, 1, 1, '2026-01-05', 60, 'unbilled', now(), now())
      RETURNING id
    SQL
    connection.execute(<<~SQL.squish)
      INSERT INTO entry_audits (company_id, entry_id, actor_type, actor_id, action, after, entry_created_at, created_at)
      VALUES (#{company_b}, #{entry_id}, 'User', 7, 'create', '{"duration": 60}', now(), now());
      INSERT INTO idempotency_records (company_id, actor_type, actor_id, operation, key, fingerprint, status, body, created_at)
      VALUES (#{company_b}, 'User', 7, 'create_entry', 'tenant-lens-b', 'fp', 201, '{}', now());
      INSERT INTO entry_outbox_items (company_id, generation, entry_id, payload, created_at)
      VALUES (#{company_b}, 1, #{entry_id}, '{}', now());
      INSERT INTO audits (action, auditable_type, auditable_id, associated_type, associated_id, version, created_at)
      VALUES ('create', 'TimesheetEntry', #{entry_id}, 'Company', #{company_b}, 1, now())
    SQL

    counts_a = described_class.monolith_counts(company_id: company_a)
    counts_b = described_class.monolith_counts(company_id: company_b)

    expect(counts_a).not_to be_empty
    expect(counts_a.values).to all(eq(0))
    expect(counts_b.keys).to match_array(counts_a.keys)
    expect(counts_b.values.sum).to be > 0
  end
end


RSpec.describe LiveHandoff do
  # "then adding an entry, raising one entry's version, adding an audit row and adding a receipt for company A changes exactly the matching counts of A and leaves every count of company B unchanged."
  it "monolith_counts leaves every count of company B unchanged when entries, versions, audits and receipts are added for company A" do
    company_a = 910_011
    company_b = 910_012
    connection = ActiveRecord::Base.connection
    insert_entry = lambda do |company_id, version|
      connection.select_value(<<~SQL.squish)
        INSERT INTO entries (company_id, version, project_id, user_id, work_date, duration, bill_status, created_at, updated_at)
        VALUES (#{company_id}, #{version}, 1, 1, '2026-01-05', 60, 'unbilled', now(), now())
        RETURNING id
      SQL
    end
    a_entry = insert_entry.call(company_a, 1)
    b_entry = insert_entry.call(company_b, 3)
    insert_entry.call(company_b, 2)
    connection.execute(<<~SQL.squish)
      INSERT INTO audits (action, auditable_type, auditable_id, associated_type, associated_id, version, created_at)
      VALUES ('create', 'TimesheetEntry', #{b_entry}, 'Company', #{company_b}, 1, now());
      INSERT INTO idempotency_records (company_id, actor_type, actor_id, operation, key, fingerprint, status, body, created_at)
      VALUES (#{company_b}, 'User', 7, 'create_entry', 'tenant-lens-b-1', 'fp', 201, '{}', now())
    SQL
    counts_a_before = described_class.monolith_counts(company_id: company_a)
    counts_b_before = described_class.monolith_counts(company_id: company_b)

    insert_entry.call(company_a, 1)
    connection.execute("UPDATE entries SET version = version + 1 WHERE id = #{Integer(a_entry)}")
    connection.execute(<<~SQL.squish)
      INSERT INTO audits (action, auditable_type, auditable_id, associated_type, associated_id, version, created_at)
      VALUES ('update', 'TimesheetEntry', #{a_entry}, 'Company', #{company_a}, 2, now());
      INSERT INTO idempotency_records (company_id, actor_type, actor_id, operation, key, fingerprint, status, body, created_at)
      VALUES (#{company_a}, 'User', 7, 'create_entry', 'tenant-lens-a-1', 'fp', 201, '{}', now())
    SQL

    expect(described_class.monolith_counts(company_id: company_b)).to eq(counts_b_before)
    expect(described_class.monolith_counts(company_id: company_a)).not_to eq(counts_a_before)
  end
end


RSpec.describe LiveHandoff do
  # "`TenantStateDigest.GROUPS` omits the audit tables and `legacy_create_receipts`, so these counts must stand on their own proof"
  it "monolith_counts does not count a TimesheetEntry audit associated with another company or an audit of another model" do
    company_a = 910_021
    company_b = 910_022
    connection = ActiveRecord::Base.connection
    before = described_class.monolith_counts(company_id: company_a)

    connection.execute(<<~SQL.squish)
      INSERT INTO audits (action, auditable_type, auditable_id, associated_type, associated_id, version, created_at)
      VALUES ('create', 'TimesheetEntry', 424242, 'Company', #{company_b}, 1, now());
      INSERT INTO audits (action, auditable_type, auditable_id, associated_type, associated_id, version, created_at)
      VALUES ('create', 'Invoice', 424243, 'Company', #{company_a}, 1, now())
    SQL

    expect(described_class.monolith_counts(company_id: company_a)).to eq(before)

    connection.execute(<<~SQL.squish)
      INSERT INTO audits (action, auditable_type, auditable_id, associated_type, associated_id, version, created_at)
      VALUES ('create', 'TimesheetEntry', 424244, 'Company', #{company_a}, 1, now())
    SQL

    after = described_class.monolith_counts(company_id: company_a)
    changed = after.keys.select { |key| after[key] != before[key] }
    expect(changed.size).to eq(1)
    expect(after[changed.first] - before[changed.first]).to eq(1)
  end
end


RSpec.describe LiveHandoff do
  context "live Timekeeping counts for two companies", :integrated_runtime, committed_data: true do
    # "With rows seeded for both companies, the per-company counts return exact values, and adding an entry, a
    # version, an audit row or a receipt for one company changes only that company's matching count"
    it "timekeeping_counts moves only company A's matching counts when an entry, a version, an audit row and a receipt are added for A" do
      url = ENV.fetch(TimekeepingDatabaseReset::DATABASE_URL_KEY)
      TestDatabaseGuard.require_test_database_url!(url)
      company_a = 9_525_101
      company_b = 9_525_102
      connection = TimekeepingDatabaseReset.connect(url, TimekeepingDatabaseReset.database_name(url))
      add_entry = lambda do |company_id|
        connection.exec_params(
          "INSERT INTO entries (company_id, project_id, user_id, work_date, duration, bill_status, created_at, " \
          "updated_at) VALUES ($1, 1, 1, CURRENT_DATE, 60, 'unbilled', now(), now()) RETURNING id", [company_id]
        ).getvalue(0, 0).to_i
      end
      add_audit = lambda do |company_id, entry_id|
        connection.exec_params(
          "INSERT INTO audit_events (company_id, entry_id, actor_type, actor_name, action, after, entry_created_at, " \
          "created_at) VALUES ($1, $2, 'service', 'live_handoff_spec', 'create', '{}', now(), now())",
          [company_id, entry_id]
        )
      end
      add_receipt = lambda do |company_id|
        connection.exec_params(
          "INSERT INTO idempotency_receipts (company_id, actor_type, actor_id, operation, key, fingerprint, status, " \
          "body, created_at) VALUES ($1, 'user', 1, 'create', $2, 'live_handoff', 201, '{}', now())",
          [company_id, SecureRandom.uuid]
        )
      end

      # Company B gets more rows than A, so a query that drops its company filter or adds both companies together
      # cannot return B's counts unchanged.
      entry_a = add_entry.call(company_a)
      add_audit.call(company_a, entry_a)
      add_receipt.call(company_a)
      3.times do
        entry_b = add_entry.call(company_b)
        add_audit.call(company_b, entry_b)
        add_receipt.call(company_b)
      end
      counts = ->(company_id) { described_class.timekeeping_counts(company_id:, env: ENV) }
      expect(counts.call(company_a)).not_to eq(counts.call(company_b))

      mutations = {
        "add an entry" => [-> { add_entry.call(company_a) }, 2],
        "raise one entry's version" => [
          -> { connection.exec_params("UPDATE entries SET version = version + 1 WHERE id = $1", [entry_a]) }, 1
        ],
        "add an audit row" => [-> { add_audit.call(company_a, entry_a) }, 1],
        "add a receipt" => [-> { add_receipt.call(company_a) }, 1]
      }

      mutations.each do |label, (mutate, changed_key_count)|
        before_a = counts.call(company_a)
        before_b = counts.call(company_b)

        mutate.call

        after_a = counts.call(company_a)
        changed = after_a.keys.reject { |key| after_a.fetch(key) == before_a.fetch(key) }
        # An entry moves the entry count and the version sum; each other write moves exactly one count.
        expect(changed.size).to eq(changed_key_count), label
        changed.each { |key| expect(after_a.fetch(key)).to eq(before_a.fetch(key) + 1), "#{label} #{key}" }
        expect(counts.call(company_b)).to eq(before_b), label
      end
    ensure
      if connection
        %w[audit_events idempotency_receipts entries].each do |table|
          connection.exec_params(
            "DELETE FROM #{connection.quote_ident(table)} WHERE company_id = ANY($1::bigint[])",
            [PG::TextEncoder::Array.new.encode([company_a, company_b])]
          )
        end
        connection.close
      end
    end
  end
end


RSpec.describe "LiveHandoff" do
  it "reconciliation_failures passes a clean two-company report and fails each bad report shape" do
    company = lambda do |id, **overrides|
      { "company_id" => id, "abort" => false, "checks" => {}, "listed" => [], "unlisted" => [] }.merge(overrides)
    end
    clean = {
      "abort" => false,
      "companies" => { "11" => company.call(11), "22" => company.call(22) },
      "unassigned" => []
    }
    difference = { "check" => "entries", "reason" => "missing" }

    # "require exactly both seeded company ids, each with `abort` false and `unlisted` empty, and `unassigned` empty."
    expect(LiveHandoff.reconciliation_failures(clean, company_ids: [11, 22])).to eq([])

    # "a reconciliation report that is missing a company, has `abort` true, or has a non-empty `unlisted` or `unassigned` fails;"
    bad_reports = {
      "missing company" => clean.merge("companies" => { "11" => company.call(11) }),
      "extra company" => clean.merge("companies" => clean["companies"].merge("33" => company.call(33))),
      "company abort true" => clean.merge("companies" => clean["companies"].merge("22" => company.call(22, "abort" => true))),
      "company abort null" => clean.merge("companies" => clean["companies"].merge("22" => company.call(22, "abort" => nil))),
      "company abort missing" => clean.merge("companies" => clean["companies"].merge("22" => company.call(22).except("abort"))),
      "unlisted non-empty" => clean.merge("companies" => clean["companies"].merge("11" => company.call(11, "unlisted" => [difference]))),
      "unlisted missing" => clean.merge("companies" => clean["companies"].merge("11" => company.call(11).except("unlisted"))),
      "unassigned non-empty" => clean.merge("unassigned" => [difference]),
      "unassigned missing" => clean.except("unassigned")
    }

    bad_reports.each do |label, report|
      expect(LiveHandoff.reconciliation_failures(report, company_ids: [11, 22])).not_to be_empty, label
    end
  end
end


RSpec.describe "LiveHandoff" do
  it "foreign_id_failures fails a company with no rows of its own, including an empty company list, and passes clean rows" do
    clean = {
      1 => [{ "company_id" => 1 }, { "company_ids" => [1] }],
      2 => [{ "company_id" => 2 }]
    }
    expect(LiveHandoff.foreign_id_failures(clean, company_ids: [1, 2])).to eq([])

    # "a foreign-id check where the company has no rows of its own fails."
    bad_inputs = {
      "empty company list" => { 1 => [{ "company_ids" => [] }], 2 => [{ "company_id" => 2 }] },
      "no rows" => { 1 => [], 2 => [{ "company_id" => 2 }] },
      "company missing" => { 2 => [{ "company_id" => 2 }] },
      "row with no company field" => { 1 => [{ "id" => 5 }], 2 => [{ "company_id" => 2 }] },
      "row naming the other company" => { 1 => [{ "company_id" => 1 }, { "company_id" => 2 }], 2 => [{ "company_id" => 2 }] },
      "list naming the other company" => { 1 => [{ "company_ids" => [1, 2] }], 2 => [{ "company_id" => 2 }] }
    }

    bad_inputs.each do |label, rows|
      expect(LiveHandoff.foreign_id_failures(rows, company_ids: [1, 2])).not_to be_empty, label
    end
  end
end


RSpec.describe "LiveHandoff" do
  it "replay_verdict refuses only exact table pairs and answers only byte-equal 2xx bodies" do
    receipt = '{"notice":"saved","entry":{"id":7}}'
    web_422 = { errors: I18n.t("errors.entry_write_rejected") }.to_json
    verdict = lambda do |status, body, refusals|
      LiveHandoff.replay_verdict(status:, body:, expected_body: receipt, refusals:)
    end

    expect(verdict.call(200, receipt.dup, LiveHandoff::MONOLITH_REFUSALS)).to eq(:answered_from_receipt)
    expect(verdict.call(200, receipt.sub("7", "8"), LiveHandoff::MONOLITH_REFUSALS)).to eq(:failed)

    # "the web 422 body is a refusal on the web table but not on the Timekeeping table;"
    expect(verdict.call(422, web_422, LiveHandoff::MONOLITH_REFUSALS)).to eq(:refused)
    expect(verdict.call(422, web_422, LiveHandoff::TIMEKEEPING_REFUSALS)).to eq(:failed)

    # "a 500 or any other body fails;"
    expect(verdict.call(500, receipt.dup, LiveHandoff::MONOLITH_REFUSALS)).to eq(:failed)
    expect(verdict.call(422, { errors: "something else" }.to_json, LiveHandoff::MONOLITH_REFUSALS)).to eq(:failed)
    expect(verdict.call(422, "not json", LiveHandoff::MONOLITH_REFUSALS)).to eq(:failed)
    expect(verdict.call(422, "[]", LiveHandoff::TIMEKEEPING_REFUSALS)).to eq(:failed)

    # "404 counts only with the cross-company table."
    not_found = { reason: "not_found" }.to_json
    expect(verdict.call(404, not_found, LiveHandoff::CROSS_COMPANY_REFUSALS)).to eq(:refused)
    expect(verdict.call(404, not_found, LiveHandoff::TIMEKEEPING_REFUSALS)).to eq(:failed)
    expect(verdict.call(404, not_found, LiveHandoff::MONOLITH_REFUSALS)).to eq(:failed)
  end
end


RSpec.describe "LiveHandoff" do
  it "refusal tables hold the exact status and body pairs each route renders" do
    # "the Timekeeping entry API renders 422 `{ reason: idempotency_key_reused }` (contracts/timekeeping/idempotency.yml `errors.key_reused.body`) and 409 `{ reason: stale_generation }`;"
    expect(LiveHandoff::TIMEKEEPING_REFUSALS).to contain_exactly(
      { status: 422, body: { "reason" => "idempotency_key_reused" } },
      { status: 409, body: { "reason" => "stale_generation" } }
    )

    # "monolith web and CLI routes render 422 as exactly `{ errors: I18n.t("errors.entry_write_rejected") }` and 409 with `reason: stale_generation` (app/controllers/concerns/error_handler.rb);"
    expect(LiveHandoff::MONOLITH_REFUSALS).to contain_exactly(
      { status: 422, body: { "errors" => I18n.t("errors.entry_write_rejected") } },
      { status: 409, body: { "errors" => I18n.t("errors.stale_generation"), "reason" => "stale_generation" } }
    )

    # "404 is a refusal only in the cross-company table."
    expect(LiveHandoff::CROSS_COMPANY_REFUSALS).to include({ status: 404, body: { "reason" => "not_found" } })
    expect(LiveHandoff::TIMEKEEPING_REFUSALS.pluck(:status)).not_to include(404)
    expect(LiveHandoff::MONOLITH_REFUSALS.pluck(:status)).not_to include(404)
  end
end


RSpec.describe LiveHandoff do
  it "send_request returns the status and the exact response bytes, unparsed and binary" do
    raw = "{\"reason\":\"idempotency_key_reused\"}\n\xFF\x00".b
    stub_request(:post, "http://127.0.0.1:4987/api/v1/companies/7/entries")
      .to_return(status: 422, body: raw, headers: { "Content-Type" => "application/json" })
    request = {
      method: "POST", path: "/api/v1/companies/7/entries",
      headers: { "Idempotency-Key" => "send-request-raw-bytes" }, body: { "note" => "raw" }
    }

    # "an HTTP sender that returns raw bytes"
    reply = described_class.send_request("http://127.0.0.1:4987", request)

    expect(reply.status).to eq(422)
    expect(reply.body).to eq(raw)
    expect(reply.body.encoding).to eq(Encoding::BINARY)
    expect(reply.body.bytesize).to eq(raw.bytesize)
  end
end


RSpec.describe LiveHandoff, type: :request do
  it "expected_web_reply equals the body the web controller rendered for a legacy create with an Idempotency-Key" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    project = create(:project, billable: true, client: create(:client, company:))
    create(:employment, company:, user:)
    user.add_role :admin, company
    create(:project_member, user:, project:)
    sign_in user

    send_request :post, api_v1_timesheet_entry_index_path, params: {
      project_id: project.id, user_id: user.id,
      timesheet_entry: { duration: 35, work_date: Date.current.iso8601, note: "Expected web reply", bill_status: :unbilled }
    }, headers: auth_headers(user).merge("Idempotency-Key" => "expected-web-reply-#{SecureRandom.uuid}")
    expect(response).to be_successful

    entry_id = JSON.parse(response.body).fetch("entry").fetch("id")
    receipt = Timekeeping::LegacyCreateReceipt.find_by!(timesheet_entry_id: entry_id)

    # "Prove in its spec that it equals the controller's own rendering for the same entry."
    expect(described_class.expected_web_reply(receipt.entry_attributes, action: :create)).to eq(response.body)
  end
end


RSpec.describe LiveHandoff do
  it "foreign_id_failures fails a company whose only row lists no company at all" do
    # "a foreign-id check where the company has no rows of its own fails."
    # entry_snapshot_receipts.company_ids may be an empty array, so a row can sit
    # under company 1 without naming it.
    rows_by_company = {
      1 => [{ "company_ids" => [] }],
      2 => [{ "company_id" => 2 }]
    }

    failures = described_class.foreign_id_failures(rows_by_company, company_ids: [1, 2])

    expect(failures).not_to be_empty
    expect(failures.join("\n")).to include("1")

    clean = { 1 => [{ "company_ids" => [1] }], 2 => [{ "company_id" => 2 }] }
    expect(described_class.foreign_id_failures(clean, company_ids: [1, 2])).to eq([])
  end
end


RSpec.describe LiveHandoff do
  it "replay_verdict fails a non-JSON body, a refusal body with an extra key and a one-byte-different receipt reply without raising" do
    stored = '{"notice":"saved","entry":{"id":7,"note":"abc"}}'

    # "a 500 or any other body fails"
    expect(described_class.replay_verdict(status: 422, body: "<html>oops</html>", expected_body: stored,
                                          refusals: described_class::TIMEKEEPING_REFUSALS)).to eq(:failed)
    expect(described_class.replay_verdict(status: 422, body: '{"reason":"idempotency_key_reused","entry":{"id":7}}',
                                          expected_body: stored,
                                          refusals: described_class::TIMEKEEPING_REFUSALS)).to eq(:failed)
    expect(described_class.replay_verdict(status: 200, body: stored.sub("abc", "abd"), expected_body: stored,
                                          refusals: described_class::TIMEKEEPING_REFUSALS)).to eq(:failed)
    # A byte-equal body with an error status is not an answer from the receipt.
    expect(described_class.replay_verdict(status: 500, body: stored, expected_body: stored,
                                          refusals: described_class::TIMEKEEPING_REFUSALS)).to eq(:failed)

    expect(described_class.replay_verdict(status: 200, body: stored.dup, expected_body: stored,
                                          refusals: described_class::TIMEKEEPING_REFUSALS)).to eq(:answered_from_receipt)
  end
end


RSpec.describe LiveHandoff do
  # "restore the integrations in `ensure`, even when a handoff raises."
  it "with_live_handoff_integrations rebuilds from the restored ENV when the handoff block raises" do
    extend LiveHandoff::ExampleHelpers

    keys = [
      Timekeeping::EntryApiClient::BASE_URL_ENV,
      Internal::V1::BaseController::SERVICE_TOKEN_ENV,
      Timekeeping::UserToken::PRIVATE_KEY_ENV
    ]
    outer = keys.index_with { |key| "outer-#{key.downcase}" }
    runtime = Struct.new(:timekeeping_url, :credentials).new(
      "http://127.0.0.1:1", TimekeepingDemo::Credentials.generate
    )
    seen = []
    rebuild = -> { seen << keys.index_with { |key| ENV.fetch(key, nil) } }
    handoff_failure = Class.new(StandardError)

    with_timekeeping_env(outer) do
      expect do
        with_live_handoff_integrations(runtime, rebuild:) { raise handoff_failure, "handoff failed mid-run" }
      end.to raise_error(handoff_failure)

      expect(seen.size).to eq(2)
      expect(seen.first.fetch(Timekeeping::EntryApiClient::BASE_URL_ENV)).to eq("http://127.0.0.1:1")
      expect(seen.last).to eq(outer)
      expect(keys.index_with { |key| ENV.fetch(key, nil) }).to eq(outer)
    end
  end
end


RSpec.describe LiveHandoff do
  # The issue's meta case: "the expected web reply differs by one byte when the receipt note changes".
  it "expected_web_reply follows the receipt note by exactly one byte even after the live row changed" do
    entry = create(:timesheet_entry, note: "receipt note a")
    receipt_attributes = entry.attributes_for_database
    # A later edit to the live row must not reach a reply rebuilt from the receipt.
    entry.update_column(:note, "edited after the receipt")

    original = described_class.expected_web_reply(receipt_attributes, action: "create")
    changed = described_class.expected_web_reply(receipt_attributes.merge("note" => "receipt note b"), action: "create")

    expect(JSON.parse(original).dig("entry", "note")).to eq("receipt note a")
    expect(JSON.parse(original).fetch("notice")).to eq(I18n.t("timesheet_entry.create.message"))
    expect(changed.bytesize).to eq(original.bytesize)
    differing = original.bytes.zip(changed.bytes).count { |left, right| left != right }
    expect(differing).to eq(1)
  end
end


RSpec.describe LiveHandoff do
  # "The live `tenant_counts` meta example carries `committed_data` and `:integrated_runtime` and follows the
  # database reset rule, though it lives under `spec/meta`". The integration tag check reads only
  # spec/integration/timekeeping, so this example keeps the live groups of this file tagged.
  it "keeps every live Timekeeping counts group in this file tagged :integrated_runtime and committed_data" do
    this_file = File.expand_path(__FILE__)
    live_groups = RSpec.world.example_groups.flat_map(&:descendants).select do |group|
      group.metadata[:absolute_file_path] == this_file &&
        group.description == "live Timekeeping counts for two companies"
    end

    expect(live_groups.size).to eq(2)
    live_groups.each do |group|
      expect(group.metadata).to include(integrated_runtime: true, committed_data: true)
    end
  end
end
