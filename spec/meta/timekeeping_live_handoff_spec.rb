# frozen_string_literal: true

require "rails_helper"
require "pg"
require "securerandom"
require "socket"

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
        "Authorization" => a_bearer,
        # Header names are case-insensitive, so a recording may hold any spelling.
        "authorization" => a_bearer,
        "x-auth-TOKEN" => a_token,
        "X-AUTH-EMAIL" => "owner-a@example.test"
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
    credential_names = replay.fetch(:headers).keys.select do |name|
      %w[authorization x-auth-email x-auth-token].include?(name.downcase)
    end
    expect(credential_names).to contain_exactly("X-Auth-Email", "X-Auth-Token")
    expect(replay.fetch(:headers).values).not_to include(a_token, a_bearer, "owner-a@example.test")
    expect(recorded).to eq(original)
  end

  context "more tests 10" do
    it "cross_company_web_refusals counts only the exact not-found pair and the monolith refusals, and fails company B's stored reply or any 2xx" do
      message = "Couldn't find Project with 'id'=4242"
      refusals = described_class.cross_company_web_refusals(not_found_message: message)
      expect(refusals).to be_frozen

      company_b_reply = { notice: "Timesheet entry created", entry: { id: 77, note: "company B note" } }.to_json

      # "Refusals count only as the exact per-route status and body pairs in `LiveHandoff`'s refusal tables. Anything else fails, including a 5xx or a connection error."
      expect(described_class.replay_verdict(status: 404, body: { errors: message }.to_json,
                                            expected_body: company_b_reply, refusals:)).to eq(:refused)
      expect(described_class.replay_verdict(status: 404, body: { errors: "#{message} [WHERE other]" }.to_json,
                                            expected_body: company_b_reply, refusals:)).to eq(:failed)
      expect(described_class.replay_verdict(status: 500, body: { errors: message }.to_json,
                                            expected_body: company_b_reply, refusals:)).to eq(:failed)
      # Timekeeping's own not_found body is no refusal on the monolith web route.
      expect(described_class.replay_verdict(status: 404, body: { reason: "not_found" }.to_json,
                                            expected_body: company_b_reply, refusals:)).to eq(:failed)
      described_class::MONOLITH_REFUSALS.each do |pair|
        expect(refusals).to include(pair)
      end

      # "A must never get B's reply, and neither company's counts may change."
      # Judged against an empty expected body, so B's own bytes can never count as an answer from a receipt.
      expect(described_class.replay_verdict(status: 200, body: company_b_reply, expected_body: "",
                                            refusals:)).to eq(:failed)
      expect(refusals.map { |pair| pair.fetch(:status) }).to all(satisfy { |status| !(200..299).cover?(status) })

      # The same-company monolith table still counts no 404.
      expect(described_class.replay_verdict(status: 404, body: { errors: message }.to_json, expected_body: company_b_reply,
                                            refusals: described_class::MONOLITH_REFUSALS)).to eq(:failed)
    end
  end

  context "more tests 12" do
    it "monolith counts include legacy_entry_write_receipts for one company only, so a replay that stores a new update receipt is seen" do
      company_a = create(:company)
      company_b = create(:company)
      project = create(:project, billable: true, client: create(:client, company: company_a))
      admin = create(:user, current_workspace_id: company_a.id).tap do |user|
        create(:employment, company: company_a, user:)
        user.add_role :admin, company_a
      end
      entry = create(:timesheet_entry, user: admin, project:, bill_status: :unbilled)
      before_a = described_class.monolith_counts(company_id: company_a.id)
      before_b = described_class.monolith_counts(company_id: company_b.id)

      Timekeeping::Gateway.new(
        context: Timekeeping::WriteContext.new(company: company_a, actor: admin, actor_kind: "user",
                                               request_id: "req-count-receipt", idempotency_key: "count-receipt-key")
      ).update(entry_id: entry.id, project:, authorize: ->(_entry) { },
               attributes: { duration: 30, work_date: Date.current, note: "Counted", bill_status: "unbilled" })

      # "Bracket every replay with `LiveHandoff.tenant_counts` for each company in both stores: entries, version sums, `audits`, `entry_audits`, `audit_events`, receipts and outbox."
      after_a = described_class.monolith_counts(company_id: company_a.id)
      expect(after_a.fetch(:legacy_entry_write_receipts) - before_a.fetch(:legacy_entry_write_receipts)).to eq(1)
      # "Never add the two companies' counts together."
      expect(described_class.monolith_counts(company_id: company_b.id)).to eq(before_b)
    end
  end

  context "more tests 13" do
    it "the monolith table counts the key-reused reply ErrorHandler renders as a refusal and the Timekeeping table does not" do
      receipt = '{"notice":"saved","entry":{"id":7}}'
      key_reused = { errors: I18n.t("errors.entry_write_rejected"), reason: "idempotency_key_reused" }.to_json
      verdict = lambda do |refusals|
        described_class.replay_verdict(status: 422, body: key_reused, expected_body: receipt, refusals:)
      end

      # "Refusals count only as the exact per-route status and body pairs in `LiveHandoff`'s refusal tables. Anything else fails, including a 5xx or a connection error."
      expect(verdict.call(described_class::MONOLITH_REFUSALS)).to eq(:refused)
      expect(verdict.call(described_class::TIMEKEEPING_REFUSALS)).to eq(:failed)
      expect(described_class.replay_verdict(status: 500, body: key_reused, expected_body: receipt,
                                            refusals: described_class::MONOLITH_REFUSALS)).to eq(:failed)
    end
  end

  context "more tests 19" do
    it "expected_web_reply_from_row renders the stored owner row's fields, not the live row's, and refuses a row of another company" do
      company = create(:company)
      user = create(:user, current_workspace_id: company.id)
      create(:employment, company:, user:)
      project = create(:project, client: create(:client, company:))
      entry = create(:timesheet_entry, user:, project:, note: "stored owner row note")
      # An owner receipt stores the row as JSON, so the row is read back through JSON as it would be.
      row = JSON.parse(entry.attributes.merge("company_id" => company.id, "discarded_at" => nil).to_json)
      stored_attributes = entry.attributes_for_database
      entry.update_column(:note, "edited after the receipt")

      # "Byte equality always uses the persisted receipt, read back at replay time"
      reply = described_class.expected_web_reply_from_row(row, company:, action: :update)

      expect(JSON.parse(reply).fetch("notice")).to eq(I18n.t("timesheet_entry.update.message"))
      expect(JSON.parse(reply).dig("entry", "note")).to eq("stored owner row note")
      expect(JSON.parse(reply).dig("entry", "id")).to eq(entry.id)
      # The same entry fields must render the same bytes whichever receipt kind stored them.
      expect(reply).to eq(described_class.expected_web_reply(stored_attributes.merge("company_id" => company.id), action: :update))

      other_company = create(:company)
      expect { described_class.expected_web_reply_from_row(row, company: other_company, action: :update) }
        .to raise_error(StandardError)
    end
  end

  context "more tests 2" do
  it "expected_web_destroy_reply is the destroy notice alone and only a byte-equal 2xx reply counts as answered" do
    expected = described_class.expected_web_destroy_reply

    expect(JSON.parse(expected)).to eq({ "notice" => I18n.t("timesheet_entry.destroy.message") })
    expect(described_class.replay_verdict(status: 200, body: expected, expected_body: expected, refusals: []))
      .to eq(:answered_from_receipt)
    # A refused retry is not an answer from the receipt, so the destroy capture's empty refusal list fails it.
    key_reused = { "errors" => I18n.t("errors.entry_write_rejected"),
                   "reason" => Timekeeping::Gateway::KEY_REUSED_REASON }.to_json
    expect(described_class.replay_verdict(status: 422, body: key_reused, expected_body: expected, refusals: []))
      .to eq(:failed)
    expect(described_class.replay_verdict(status: 404, body: { errors: "not found" }.to_json, expected_body: expected,
                                          refusals: [])).to eq(:failed)
  end
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
    insert_legacy_entry_write_receipt = lambda do |company_id|
      connection.exec_query(
        "INSERT INTO legacy_entry_write_receipts (company_id, actor_kind, actor_id, operation, key, fingerprint, " \
        "timesheet_entry_id, entry_attributes, created_at, expires_at) VALUES ($1, 'user', 1, 'update', $2, 'fp', " \
        "1, '{}', now(), now() + interval '1 day')",
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
        insert_legacy_entry_write_receipt.call(company_id)
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
    # Two rows per table for A, with a version sum of 2 * 3 = 6; one row per table for B, version sum 1.
    expect(a_counts).to eq(
      timesheet_entries: 2, entries: 2, entry_versions: 6, timesheet_entry_audits: 2, entry_audits: 2,
      legacy_create_receipts: 2, legacy_entry_write_receipts: 2, idempotency_records: 2, entry_snapshot_receipts: 2,
      entry_outbox_items: 2
    )
    expect(b_counts).to eq(
      timesheet_entries: 1, entries: 1, entry_versions: 1, timesheet_entry_audits: 1, entry_audits: 1,
      legacy_create_receipts: 1, legacy_entry_write_receipts: 1, idempotency_records: 1, entry_snapshot_receipts: 1,
      entry_outbox_items: 1
    )

    changed_counts = lambda do |before, after|
      expect(after.keys).to match_array(before.keys)
      after.to_h { |key, value| [key, value - before.fetch(key)] }.reject { |_key, delta| delta.zero? }
    end

    # "adding an entry, raising one entry's version, adding an audit row and adding a receipt for company A changes
    # exactly the matching counts of A and leaves every count of company B unchanged."
    writes = {
      "an entry" => [-> { insert_entry.call(company_a, 1) }, { entries: 1, entry_versions: 1 }],
      "a raised version" => [-> { connection.exec_query("UPDATE entries SET version = version + 1 WHERE id = (SELECT min(id) FROM entries WHERE company_id = $1)", "live_handoff_counts", [company_a]) }, { entry_versions: 1 }],
      "an audit row" => [-> { insert_audit.call(company_a) }, { timesheet_entry_audits: 1 }],
      "a receipt" => [-> { insert_legacy_receipt.call(company_a) }, { legacy_create_receipts: 1 }],
      "a legacy update receipt" => [-> { insert_legacy_entry_write_receipt.call(company_a) }, { legacy_entry_write_receipts: 1 }]
    }
    writes.each do |label, (write, expected_changes)|
      a_before = described_class.monolith_counts(company_id: company_a)
      write.call
      expect(changed_counts.call(a_before, described_class.monolith_counts(company_id: company_a))).to eq(expected_changes), label
      expect(described_class.monolith_counts(company_id: company_b)).to eq(b_counts), label
    end
  end
end


RSpec.describe LiveHandoff do
  context "live Timekeeping counts for two companies", :integrated_runtime, committed_data: true do
    # "With rows seeded for both companies, the per-company counts return exact values, and adding an entry, a
    # version, an audit row or a receipt for one company changes only that company's matching count"
    it "timekeeping_counts returns exact values per company and moves only company A's matching counts when an entry, a version, an audit row and a receipt are added for A" do
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
      add_receipt = lambda do |company_id|
        connection.exec_params(
          "INSERT INTO idempotency_receipts (company_id, actor_type, actor_id, operation, key, fingerprint, status, " \
          "body, created_at) VALUES ($1, 'user', 1, 'create', $2, 'live_handoff', 201, '{}', now())",
          [company_id, SecureRandom.uuid]
        )
      end
      add_service_receipt = lambda do |company_id|
        connection.exec_params(
          "INSERT INTO service_idempotency_receipts (company_id, actor_name, operation, key, fingerprint, status, " \
          "body, created_at) VALUES ($1, 'live_handoff_spec', 'prepare', $2, 'live_handoff', 200, '{}', now())",
          [company_id, SecureRandom.uuid]
        )
      end
      # Written as already sent, so the runtime's relay never delivers these rows to the monolith.
      add_outbox_snapshot = lambda do |company_id, entry_id|
        connection.exec_params(
          "INSERT INTO outbox_snapshots (id, company_id, project_id, user_id, work_date, duration, bill_status, " \
          "review_status, locked, source, source_metadata, proof_metadata, created_at, updated_at, version, " \
          "generation, sent_at) VALUES ($2, $1, 1, 1, CURRENT_DATE, 60, 'unbilled', 'not_required', false, " \
          "'manual', '{}', '{}', now(), now(), 1, 1, now())",
          [company_id, entry_id]
        )
      end
      # Distinguishable seeds: A has one entry at version 2, one receipt, one service receipt and one outbox
      # snapshot; B has three entries, two audit rows, three receipts, two service receipts and three outbox
      # snapshots, so a query that drops its company filter or adds both companies together fails.
      a_entry = add_entry.call(company_a, 2)
      add_receipt.call(company_a)
      add_service_receipt.call(company_a)
      add_outbox_snapshot.call(company_a, a_entry)
      b_entries = Array.new(3) { add_entry.call(company_b, 1) }
      b_entries.first(2).each { |id| add_audit.call(company_b, id) }
      3.times { add_receipt.call(company_b) }
      2.times { add_service_receipt.call(company_b) }
      b_entries.each { |id| add_outbox_snapshot.call(company_b, id) }

      a_before = described_class.timekeeping_counts(company_id: company_a)
      b_before = described_class.timekeeping_counts(company_id: company_b)
      expect(a_before).to eq(entries: 1, entry_versions: 2, audit_events: 0, idempotency_receipts: 1,
                             service_idempotency_receipts: 1, outbox_snapshots: 1)
      expect(b_before).to eq(entries: 3, entry_versions: 3, audit_events: 2, idempotency_receipts: 3,
                             service_idempotency_receipts: 2, outbox_snapshots: 3)
      expect(described_class.tenant_counts(company_id: company_a).fetch(:timekeeping)).to eq(a_before)

      writes = {
        "add an entry" => [-> { add_entry.call(company_a, 1) }, { entries: 1, entry_versions: 1 }],
        "raise one entry's version" => [
          -> { connection.exec_params("UPDATE entries SET version = version + 4 WHERE id = $1", [a_entry]) },
          { entry_versions: 4 }
        ],
        "add an audit row" => [-> { add_audit.call(company_a, a_entry) }, { audit_events: 1 }],
        "add a receipt" => [-> { add_receipt.call(company_a) }, { idempotency_receipts: 1 }],
        "add a service receipt" => [-> { add_service_receipt.call(company_a) }, { service_idempotency_receipts: 1 }],
        "add an outbox snapshot" => [-> { add_outbox_snapshot.call(company_a, a_entry) }, { outbox_snapshots: 1 }]
      }
      writes.each do |label, (write, expected_deltas)|
        before = described_class.timekeeping_counts(company_id: company_a)
        write.call
        after = described_class.timekeeping_counts(company_id: company_a)
        deltas = after.to_h { |key, value| [key, value - before.fetch(key)] }.reject { |_key, delta| delta.zero? }
        expect(deltas).to eq(expected_deltas), label
        expect(described_class.timekeeping_counts(company_id: company_b)).to eq(b_before), label
      end
    ensure
      if connection
        [company_a, company_b].each do |id|
          %w[audit_events idempotency_receipts service_idempotency_receipts outbox_snapshots entries].each do |table|
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
    # entry_snapshot_receipts.company_ids may be an empty array, so a row can sit
    # under company 1 without naming it; the failure names that company.
    expect(LiveHandoff.foreign_id_failures(bad_inputs.fetch("empty company list"), company_ids: [1, 2]).join("\n"))
      .to include("company 1")
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
    expect(verdict.call(422, "<html>oops</html>", LiveHandoff::TIMEKEEPING_REFUSALS)).to eq(:failed)
    # A refusal body with an extra key is not the exact pair the table holds.
    expect(verdict.call(422, '{"reason":"idempotency_key_reused","entry":{"id":7}}', LiveHandoff::TIMEKEEPING_REFUSALS))
      .to eq(:failed)
    # A byte-equal body with an error status is not an answer from the receipt.
    expect(verdict.call(500, receipt.dup, LiveHandoff::TIMEKEEPING_REFUSALS)).to eq(:failed)

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
    # ErrorHandler#render_idempotency_key_reused renders the same message with the key-reused reason.
    expect(LiveHandoff::MONOLITH_REFUSALS).to contain_exactly(
      { status: 422, body: { "errors" => I18n.t("errors.entry_write_rejected") } },
      { status: 422, body: { "errors" => I18n.t("errors.entry_write_rejected"), "reason" => "idempotency_key_reused" } },
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

  it "send_request sends a request once and raises when the connection drops, without a transport retry" do
    WebMock.disable_net_connect!(allow_localhost: true)
    listener = TCPServer.new("127.0.0.1", 0)
    attempts = Queue.new
    # Drops the first connection without a reply, and answers any second attempt.
    server = Thread.new do
      loop do
        socket = listener.accept
        while (line = socket.gets) && line != "\r\n"; end
        attempts << :attempt
        socket.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok") if attempts.size > 1
        socket.close
      end
    end
    request = { method: "PUT", path: "/entry", headers: {}, body: "" }

    expect { described_class.send_request("http://127.0.0.1:#{listener.addr[1]}", request) }
      .to raise_error(EOFError, "PUT /entry could not be sent")
    expect(attempts.size).to eq(1)
  ensure
    server&.kill
    listener&.close
  end
end


# The receipt this example reads is written only by the legacy store's create
# path, so it pins the legacy owner state whatever state the run selects.
RSpec.describe LiveHandoff, type: :request, owner_state: "legacy" do
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
