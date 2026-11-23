# frozen_string_literal: true

require "rails_helper"
require "json"
require "securerandom"
require "yaml"

# Live proofs that a pre-handoff write or relay delivery sent again after a
# later cutover, rollback or re-cutover is refused or answered from the
# receipt its first attempt stored, and writes nothing. Each example runs its
# own handoffs, because the :integrated_runtime hooks empty both databases
# after every example. The :integrated_runtime tag skips them unless the live
# flag is set (spec/support/timekeeping/integrated_runtime.rb), so the default
# suite skips them, and a skip is not a pass.
#
# No relay message exists before the first cutover: the legacy store has no
# outbox, and Timekeeping::RelayJob reads only the prepared store's.
RSpec.describe "Timekeeping late replay" do
  context "more tests 2", :integrated_runtime, :two_tenant_seed, committed_data: true,
                                          owner_state: "legacy" do
  it "keeps reconciliation clean and each seeded company's money unchanged after every handoff while a pre-cutover legacy update is replayed without a second write" do
    company_ids = [fork_and_leaf.id, copper_kettle.id]
    owner = User.with_role(:owner, fork_and_leaf).first
    project = fork_and_leaf.projects.kept.first
    headers = { "X-Auth-Email" => owner.email, "X-Auth-Token" => owner.token,
                "Content-Type" => "application/json" }
    baselines = company_ids.index_with { |id| TimekeepingLiveHandoff.money(company_id: id) }

    created = LiveHandoff.send_request(@integrated_runtime.monolith_url, {
      method: "POST", path: "/api/v1/timesheet_entry",
      headers: headers.merge("Idempotency-Key" => "late-replay-create-#{SecureRandom.hex(4)}"),
      body: { "project_id" => project.id,
              "timesheet_entry" => { "duration" => 30.0, "note" => "late replay", "work_date" => "2026-01-08" } }
    })
    expect(created.status).to eq(200)
    entry_id = JSON.parse(created.body).fetch("entry").fetch("id")

    update_key = "late-replay-update-#{SecureRandom.hex(4)}"
    update_request = {
      method: "PUT", path: "/api/v1/timesheet_entry/#{entry_id}",
      headers: headers.merge("Idempotency-Key" => update_key),
      body: { "project_id" => project.id, "timesheet_entry" => { "note" => "late replay edited" } }
    }
    # "Each captured request must first answer 2xx with its receipt present."
    expect(LiveHandoff.send_request(@integrated_runtime.monolith_url, update_request).status).to eq(200)
    receipt_attributes = lambda do
      Timekeeping::LegacyEntryWriteReceipt.uncached do
        Timekeeping::LegacyEntryWriteReceipt
          .find_by!(company_id: fork_and_leaf.id, operation: "update", key: update_key).entry_attributes
      end
    end
    receipt_attributes.call

    with_live_handoff_integrations(@integrated_runtime) do
      %i[cutover rollback re_cutover].each do |direction|
        # "Reconciliation and money checks pass after each handoff run in these examples, on each seeded company (through the LiveHandoff driver or the same check)"
        run_live_handoff(direction, company_ids:)
        company_ids.each do |id|
          later = TimekeepingLiveHandoff.money(company_id: id)
          expect(Timekeeping::FinancialSnapshot.compare(baselines.fetch(id), later)).to eq([]), "#{direction}, company #{id}"
        end

        before = company_ids.index_with { |id| LiveHandoff.tenant_counts(company_id: id) }
        reply = LiveHandoff.send_request(@integrated_runtime.monolith_url, update_request)
        after = company_ids.index_with { |id| LiveHandoff.tenant_counts(company_id: id) }

        # "A replayed pre-handoff legacy-store update after cutover writes nothing again (no new version, no audit row): it is refused or answered without a second write, not left out"
        verdict = LiveHandoff.replay_verdict(
          status: reply.status, body: reply.body,
          expected_body: LiveHandoff.expected_web_reply(receipt_attributes.call, action: :update),
          refusals: LiveHandoff::MONOLITH_REFUSALS
        )
        expect(verdict).not_to eq(:failed), "legacy update replay after #{direction}"
        company_ids.each do |id|
          expect(after.fetch(id)).to eq(before.fetch(id)), "legacy update replay after #{direction}, company #{id}"
        end
      end
    end
  end
  end

  context "more tests 3", :integrated_runtime, :two_tenant_seed, committed_data: true, owner_state: "legacy" do
  it "replays each legacy web create and update captured before cutover after cutover, rollback and re-cutover without a second write" do
    company_ids = [fork_and_leaf.id, copper_kettle.id]
    monolith_url = @integrated_runtime.monolith_url
    # RELAY_LOCK_KEY in timekeeping/app/jobs/relay_job.rb; that class is not loadable from the monolith.
    timekeeping_relay_lock = 2_026_034_002
    states = lambda do
      company_ids.index_with do |id|
        [LiveHandoff.tenant_counts(company_id: id),
         TenantStateDigest.take(company_id: id, timekeeping_url: ENV.fetch(TimekeepingDatabaseReset::DATABASE_URL_KEY))]
      end
    end

    # "Bracket every replay with `LiveHandoff.tenant_counts` for each company in both stores: entries, version sums, `audits`, `entry_audits`, `audit_events`, receipts and outbox."
    # Both relay locks are held, so no relay delivery can change a count inside the bracket.
    replay = lambda do |capture, direction|
      label = "#{capture.fetch(:kind)} after #{direction}, company #{capture.fetch(:company_id)}"
      connection = ActiveRecord::Base.connection
      connection.select_value("SELECT pg_advisory_lock(#{Timekeeping::RelayJob::RELAY_LOCK_KEY})")
      before, reply, after = TimekeepingLiveHandoff.with_timekeeping_database do |timekeeping|
        timekeeping.exec("SELECT pg_advisory_lock(#{timekeeping_relay_lock})")
        [states.call, LiveHandoff.send_request(monolith_url, capture.fetch(:request)), states.call]
      end
      # "Byte equality always uses the persisted receipt, read back at replay time"
      verdict = LiveHandoff.replay_verdict(status: reply.status, body: reply.body, expected_body: capture.fetch(:expected).call,
                                           refusals: LiveHandoff::MONOLITH_REFUSALS)
      expect(verdict).not_to eq(:failed), label
      company_ids.each { |id| expect(after.fetch(id)).to eq(before.fetch(id)), "#{label}: company #{id} changed" }
    ensure
      connection&.select_value("SELECT pg_advisory_unlock(#{Timekeeping::RelayJob::RELAY_LOCK_KEY})")
    end

    with_live_handoff_integrations(@integrated_runtime) do
      captures = [fork_and_leaf, copper_kettle].flat_map do |company|
        owner = User.with_role(:owner, company).first
        project = company.projects.kept.first
        headers = ->(key) { { "X-Auth-Email" => owner.email, "X-Auth-Token" => owner.token, "Idempotency-Key" => key } }
        scope = { company_id: company.id, actor_kind: "user", actor_id: owner.id }
        create_key = "late-create-#{SecureRandom.hex(8)}"
        update_key = "late-update-#{SecureRandom.hex(8)}"
        create = { method: "POST", path: "/api/v1/timesheet_entry", headers: headers.call(create_key),
                   body: { "project_id" => project.id,
                           "timesheet_entry" => { "duration" => 30.0, "note" => "late #{create_key}", "work_date" => "2026-01-06" } } }
        created = LiveHandoff.send_request(monolith_url, create)
        # "Each captured request must first answer 2xx with its receipt present."
        expect(created.status).to eq(200), "legacy create, company #{company.id}"
        entry_id = JSON.parse(created.body).fetch("entry").fetch("id")
        update = { method: "PUT", path: "/api/v1/timesheet_entry/#{entry_id}", headers: headers.call(update_key),
                   body: { "project_id" => project.id, "timesheet_entry" => { "duration" => 45.0, "note" => "late #{update_key}" } } }
        updated = LiveHandoff.send_request(monolith_url, update)
        expect(updated.status).to eq(200), "legacy update, company #{company.id}"
        create_receipt = -> { ActiveRecord::Base.uncached { Timekeeping::LegacyCreateReceipt.find_by!(**scope, key: create_key) } }
        update_receipt = lambda do
          ActiveRecord::Base.uncached { Timekeeping::LegacyEntryWriteReceipt.find_by!(**scope, key: update_key, operation: "update") }
        end
        create_receipt.call
        update_receipt.call

        [
          { kind: "legacy create", company_id: company.id, request: create,
            expected: -> { LiveHandoff.expected_web_reply(create_receipt.call.entry_attributes, action: :create) } },
          # "A replayed pre-handoff legacy-store update after cutover writes nothing again (no new version, no audit row): it is refused or answered without a second write, not left out"
          { kind: "legacy update", company_id: company.id, request: update,
            expected: -> { LiveHandoff.expected_web_reply(update_receipt.call.entry_attributes, action: :update) } }
        ]
      end

      # "Replay each captured message unchanged after every later handoff."
      %i[cutover rollback re_cutover].each do |direction|
        run_live_handoff(direction, company_ids:)
        captures.each { |capture| replay.call(capture, direction) }
      end
    end
  end
  end

  context "more tests 4", :integrated_runtime, :two_tenant_seed, committed_data: true, owner_state: "legacy" do
  it "replays web writes accepted while Timekeeping owns through the monolith after rollback and re-cutover without writing again" do
    company_ids = [fork_and_leaf.id, copper_kettle.id]
    monolith_url = @integrated_runtime.monolith_url
    # RELAY_LOCK_KEY in timekeeping/app/jobs/relay_job.rb; that class is not loadable from the monolith.
    timekeeping_relay_lock = 2_026_034_002
    owner = User.with_role(:owner, fork_and_leaf).first
    project = fork_and_leaf.projects.kept.first
    headers = ->(key) { { "X-Auth-Email" => owner.email, "X-Auth-Token" => owner.token, "Idempotency-Key" => key } }
    states = lambda do
      company_ids.index_with do |id|
        [LiveHandoff.tenant_counts(company_id: id),
         TenantStateDigest.take(company_id: id, timekeeping_url: ENV.fetch(TimekeepingDatabaseReset::DATABASE_URL_KEY))]
      end
    end
    # The receipt Timekeeping stored for this company and entry, found by the note the write sent.
    stored_row = lambda do |entry_id, note|
      TimekeepingLiveHandoff.with_timekeeping_database do |timekeeping|
        bodies = timekeeping.exec_params("SELECT body FROM idempotency_receipts WHERE company_id = $1", [fork_and_leaf.id])
                            .column_values(0)
        rows = bodies.filter_map do |body|
          parsed = JSON.parse(body)
          parsed.is_a?(Hash) ? parsed.fetch("entry", parsed) : nil
        end
        rows.find { |row| row["id"] == entry_id && row["note"] == note } || raise("no Timekeeping receipt for entry #{entry_id}")
      end
    end
    replay = lambda do |capture, direction|
      label = "#{capture.fetch(:kind)} after #{direction}"
      connection = ActiveRecord::Base.connection
      connection.select_value("SELECT pg_advisory_lock(#{Timekeeping::RelayJob::RELAY_LOCK_KEY})")
      before, reply, after = TimekeepingLiveHandoff.with_timekeeping_database do |timekeeping|
        timekeeping.exec("SELECT pg_advisory_lock(#{timekeeping_relay_lock})")
        [states.call, LiveHandoff.send_request(monolith_url, capture.fetch(:request)), states.call]
      end
      expected = LiveHandoff.expected_web_reply_from_row(stored_row.call(capture.fetch(:entry_id), capture.fetch(:note)),
                                                         company: fork_and_leaf, action: capture.fetch(:action))
      # "Refusals count only as the exact per-route status and body pairs in `LiveHandoff`'s refusal tables. Anything else fails, including a 5xx or a connection error."
      verdict = LiveHandoff.replay_verdict(status: reply.status, body: reply.body, expected_body: expected,
                                           refusals: LiveHandoff::MONOLITH_REFUSALS)
      expect(verdict).not_to eq(:failed), label
      # "A web write accepted while Timekeeping owns, replayed unchanged through the monolith after rollback, writes nothing"
      company_ids.each { |id| expect(after.fetch(id)).to eq(before.fetch(id)), "#{label}: company #{id} changed" }
    ensure
      connection&.select_value("SELECT pg_advisory_unlock(#{Timekeeping::RelayJob::RELAY_LOCK_KEY})")
    end

    with_live_handoff_integrations(@integrated_runtime) do
      run_live_handoff(:cutover, company_ids:)

      create_key = "tk-create-#{SecureRandom.hex(8)}"
      create_note = "while Timekeeping owns #{create_key}"
      create = { method: "POST", path: "/api/v1/timesheet_entry", headers: headers.call(create_key),
                 body: { "project_id" => project.id,
                         "timesheet_entry" => { "duration" => 25.0, "note" => create_note, "work_date" => "2026-01-08" } } }
      created = LiveHandoff.send_request(monolith_url, create)
      # "Each captured request must first answer 2xx with its receipt present."
      expect(created.status).to eq(200)
      entry_id = JSON.parse(created.body).fetch("entry").fetch("id")
      update_key = "tk-update-#{SecureRandom.hex(8)}"
      update_note = "updated while Timekeeping owns #{update_key}"
      update = { method: "PUT", path: "/api/v1/timesheet_entry/#{entry_id}", headers: headers.call(update_key),
                 body: { "project_id" => project.id, "timesheet_entry" => { "duration" => 35.0, "note" => update_note } } }
      expect(LiveHandoff.send_request(monolith_url, update).status).to eq(200)
      stored_row.call(entry_id, create_note)
      stored_row.call(entry_id, update_note)

      captures = [
        { kind: "web create while Timekeeping owns", request: create, entry_id:, note: create_note, action: :create },
        { kind: "web update while Timekeeping owns", request: update, entry_id:, note: update_note, action: :update }
      ]
      %i[rollback re_cutover].each do |direction|
        run_live_handoff(direction, company_ids:)
        captures.each { |capture| replay.call(capture, direction) }
      end
    end
  end
  end

  context "more tests 5", :integrated_runtime, :two_tenant_seed, committed_data: true, owner_state: "legacy" do
  it "answers a prepared-store relay delivery captured before re-cutover from its entry snapshot receipt when it is delivered again after re-cutover" do
    company_ids = [fork_and_leaf.id, copper_kettle.id]
    monolith_url = @integrated_runtime.monolith_url
    # RELAY_LOCK_KEY in timekeeping/app/jobs/relay_job.rb; that class is not loadable from the monolith.
    timekeeping_relay_lock = 2_026_034_002
    monolith_relay_lock = Timekeeping::RelayJob::RELAY_LOCK_KEY
    owner = User.with_role(:owner, fork_and_leaf).first
    project = fork_and_leaf.projects.kept.first
    connection = ActiveRecord::Base.connection
    states = lambda do
      company_ids.index_with do |id|
        [LiveHandoff.tenant_counts(company_id: id),
         TenantStateDigest.take(company_id: id, timekeeping_url: ENV.fetch(TimekeepingDatabaseReset::DATABASE_URL_KEY))]
      end
    end
    parsed_batch = ->(batch) { batch.is_a?(String) ? JSON.parse(batch) : batch }
    receipt_for = lambda do |delivery|
      ids = parsed_batch.call(delivery.fetch(:batch)).fetch("snapshots").map { |snapshot| snapshot.fetch("entry").fetch("company_id") }
      ActiveRecord::Base.uncached do
        EntrySnapshotReceipt.find_by!(company_ids: ids.uniq.sort, actor: "timekeeping", key: delivery.fetch(:key))
      end
    end
    recorded = []

    with_live_handoff_integrations(@integrated_runtime) do
      run_live_handoff(:cutover, company_ids:)
      run_live_handoff(:rollback, company_ids:)

      # The lock is taken before the write, so the runtime's own relay worker cannot deliver it first.
      connection.select_value("SELECT pg_advisory_lock(#{monolith_relay_lock})")
      begin
        reply = LiveHandoff.send_request(monolith_url, {
          method: "POST", path: "/api/v1/timesheet_entry",
          headers: { "X-Auth-Email" => owner.email, "X-Auth-Token" => owner.token, "Idempotency-Key" => "prepared-#{SecureRandom.hex(8)}" },
          body: { "project_id" => project.id,
                  "timesheet_entry" => { "duration" => 20.0, "note" => "prepared relay #{SecureRandom.hex(4)}", "work_date" => "2026-01-09" } }
        })
        expect(reply.status).to eq(200)
        configured = Timekeeping::LocalSnapshotEndpoint.method(:configured)
        with_timekeeping_env(Timekeeping::LocalSnapshotEndpoint::PROJECTION_URL_ENV => monolith_url) do
          allow(Timekeeping::LocalSnapshotEndpoint).to receive(:configured) do
            real = configured.call
            Object.new.tap do |recorder|
              recorder.define_singleton_method(:deliver) do |batch, idempotency_key:|
                real.deliver(batch, idempotency_key:).tap do |answer|
                  recorded << { batch:, key: idempotency_key, status: answer.status }
                end
              end
            end
          end
          # The job takes the same session lock again on this connection, which Postgres allows.
          Timekeeping::RelayJob.perform_now
        end
        RSpec::Mocks.space.proxy_for(Timekeeping::LocalSnapshotEndpoint).reset
      ensure
        connection.select_value("SELECT pg_advisory_unlock(#{monolith_relay_lock})")
      end

      # "Each captured request must first answer 2xx with its receipt present."
      expect(recorded).not_to be_empty
      recorded.each do |delivery|
        expect(delivery.fetch(:status)).to eq(200)
        receipt_for.call(delivery)
      end

      run_live_handoff(:re_cutover, company_ids:)

      # "Replay each captured message unchanged after every later handoff."
      recorded.each_with_index do |delivery, index|
        request = { method: "POST", path: "/internal/v1/timekeeping/entry-snapshots",
                    headers: { "Authorization" => "Bearer #{@integrated_runtime.credentials.service_token}",
                               "Idempotency-Key" => delivery.fetch(:key), "Content-Type" => "application/json" },
                    body: delivery.fetch(:batch) }
        connection.select_value("SELECT pg_advisory_lock(#{monolith_relay_lock})")
        begin
          before, replayed, after = TimekeepingLiveHandoff.with_timekeeping_database do |timekeeping|
            timekeeping.exec("SELECT pg_advisory_lock(#{timekeeping_relay_lock})")
            [states.call, LiveHandoff.send_request(monolith_url, request), states.call]
          end
        ensure
          connection.select_value("SELECT pg_advisory_unlock(#{monolith_relay_lock})")
        end
        # "a relay delivery is answered from `entry_snapshot_receipts`."
        receipt = receipt_for.call(delivery)
        stored_body = receipt.response_body.is_a?(String) ? JSON.parse(receipt.response_body) : receipt.response_body
        expect(replayed.status).to eq(receipt.response_status), "relay delivery #{index} after re_cutover"
        expect(JSON.parse(replayed.body)).to eq(stored_body), "relay delivery #{index} after re_cutover"
        company_ids.each { |id| expect(after.fetch(id)).to eq(before.fetch(id)), "relay delivery #{index}: company #{id} changed" }
      end
    end
  end
  end

  context "every owner's captured messages", :integrated_runtime, :two_tenant_seed, committed_data: true,
                                             owner_state: "legacy" do
    it "refuses or answers from receipts the Timekeeping API writes, Timekeeping relay deliveries, prepared-store web writes and a cross-company create after every later handoff" do
      company_ids = [fork_and_leaf.id, copper_kettle.id]
      monolith_url = @integrated_runtime.monolith_url
      timekeeping_url = @integrated_runtime.timekeeping_url
      service_token = @integrated_runtime.credentials.service_token
      private_key = OpenSSL::PKey::RSA.new(@integrated_runtime.credentials.private_key_pem)
      database_url = ENV.fetch(TimekeepingDatabaseReset::DATABASE_URL_KEY)
      # RELAY_LOCK_KEY in timekeeping/app/jobs/relay_job.rb; that class is not loadable from the monolith.
      timekeeping_relay_lock = 2_026_034_002
      monolith_relay_lock = Timekeeping::RelayJob::RELAY_LOCK_KEY
      entry_fields = YAML.safe_load_file(Rails.root.join("contracts/timekeeping/entry_snapshots.yml")).fetch("entry_fields")
      connection = ActiveRecord::Base.connection
      owner = User.with_role(:owner, fork_and_leaf).first
      project = fork_and_leaf.projects.kept.first
      intruder = User.with_role(:owner, copper_kettle).first
      web_headers = ->(key) { { "X-Auth-Email" => owner.email, "X-Auth-Token" => owner.token, "Idempotency-Key" => key } }
      handoffs_done = []

      states = lambda do
        company_ids.index_with do |id|
          [LiveHandoff.tenant_counts(company_id: id), TenantStateDigest.take(company_id: id, timekeeping_url: database_url)]
        end
      end

      # Both relay locks are held around a block, so neither the runtime's
      # monolith relay nor its Timekeeping relay can deliver inside it. The
      # Timekeeping lock is blocking, so a relay run already past its pause
      # check finishes before the block starts.
      with_relays_held = lambda do |&block|
        connection.select_value("SELECT pg_advisory_lock(#{monolith_relay_lock})")
        TimekeepingLiveHandoff.with_timekeeping_database do |timekeeping|
          timekeeping.exec("SELECT pg_advisory_lock(#{timekeeping_relay_lock})")
          block.call(timekeeping)
        end
      ensure
        connection.select_value("SELECT pg_advisory_unlock(#{monolith_relay_lock})")
      end

      # "Bracket every replay with `LiveHandoff.tenant_counts` for each company in both stores: entries, version sums, `audits`, `entry_audits`, `audit_events`, receipts and outbox. Also compare `TenantStateDigest.take`. Never add the two companies' counts together."
      replay = lambda do |capture, direction|
        label = "#{capture.fetch(:kind)} after #{direction}"
        before, reply, after = with_relays_held.call do
          [states.call, LiveHandoff.send_request(capture.fetch(:base_url), capture.fetch(:request).call), states.call]
        end
        # "Refusals count only as the exact per-route status and body pairs in `LiveHandoff`'s refusal tables. Anything else fails, including a 5xx or a connection error."
        expect(capture.fetch(:verdict).call(reply)).not_to eq(:failed), "#{label} answered #{reply.status}"
        company_ids.each { |id| expect(after.fetch(id)).to eq(before.fetch(id)), "#{label}: company #{id} changed" }
      end

      # The receipt row an owner stored for this company, actor and entry,
      # found by the note the write sent, read back now.
      stored_row = lambda do |rows, entry_id, note|
        rows.each do |body, status|
          parsed = JSON.parse(body)
          row = parsed.is_a?(Hash) ? parsed.fetch("entry", parsed) : nil
          return [body, status, row] if row.is_a?(Hash) && row["id"] == entry_id && row["note"] == note
        end
        raise "no stored receipt for entry #{entry_id}"
      end
      timekeeping_receipt = lambda do |entry_id, note|
        rows = TimekeepingLiveHandoff.with_timekeeping_database do |timekeeping|
          timekeeping.exec_params("SELECT body, status FROM idempotency_receipts WHERE company_id = $1 AND actor_id = $2",
                                  [fork_and_leaf.id, owner.id]).values
        end
        stored_row.call(rows, entry_id, note)
      end
      prepared_receipt = lambda do |entry_id, note|
        rows = ActiveRecord::Base.uncached do
          connection.select_rows("SELECT body, status FROM idempotency_records WHERE company_id = $1 AND actor_id = $2",
                                 "prepared receipts", [fork_and_leaf.id, owner.id])
        end
        stored_row.call(rows, entry_id, note)
      end
      ownership_generation = lambda do
        TimekeepingOwnership.uncached { TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).generation }
      end

      # Company B (Fork & Leaf) writes a legacy web create before cutover.
      cross_key = "cross-#{SecureRandom.hex(8)}"
      cross_create = { method: "POST", path: "/api/v1/timesheet_entry", headers: web_headers.call(cross_key),
                       body: { "project_id" => project.id,
                               "timesheet_entry" => { "duration" => 15.0, "note" => "cross #{cross_key}", "work_date" => "2026-01-05" } } }
      # "Each captured request must first answer 2xx with its receipt present."
      expect(LiveHandoff.send_request(monolith_url, cross_create).status).to eq(200)
      cross_receipt = lambda do
        ActiveRecord::Base.uncached do
          Timekeeping::LegacyCreateReceipt.find_by!(company_id: fork_and_leaf.id, actor_kind: "user", actor_id: owner.id, key: cross_key)
        end
      end
      cross_receipt.call
      # The controller looks the recorded project up inside company A before any
      # receipt is read; the same scoped find gives the exact not-found message.
      not_found_message = begin
        copper_kettle.projects.kept.find(project.id)
        raise "company #{copper_kettle.id} can read company #{fork_and_leaf.id}'s project"
      rescue ActiveRecord::RecordNotFound => error
        error.message
      end
      # "Use `LiveHandoff.web_replay_request` for company A replaying company B's legacy web create after each handoff, including after rollback. A must never get B's reply, and neither company's counts may change."
      cross_company = {
        kind: "company #{copper_kettle.id} replaying company #{fork_and_leaf.id}'s legacy create", base_url: monolith_url,
        request: lambda {
          LiveHandoff.web_replay_request(cross_create, company_id: copper_kettle.id, auth_email: intruder.email,
                                                       auth_token: intruder.token)
        },
        verdict: lambda { |reply|
          b_reply = LiveHandoff.expected_web_reply(cross_receipt.call.entry_attributes, action: :create)
          next :failed if reply.body.b == b_reply.b

          refusals = LiveHandoff.cross_company_web_refusals(not_found_message:)
          LiveHandoff.replay_verdict(status: reply.status, body: reply.body, expected_body: b_reply, refusals:) == :refused ? :refused : :failed
        }
      }

      captures = []
      with_live_handoff_integrations(@integrated_runtime) do
        run_handoff = lambda do |direction|
          # "Reconciliation and money checks pass after each handoff run in these examples, on each seeded company (through the LiveHandoff driver or the same check)"
          baselines = company_ids.index_with { |id| TimekeepingLiveHandoff.money(company_id: id) }
          run_live_handoff(direction, company_ids:)
          company_ids.each do |id|
            later = TimekeepingLiveHandoff.money(company_id: id)
            expect(Timekeeping::FinancialSnapshot.compare(baselines.fetch(id), later)).to eq([]), "#{direction}, company #{id}"
          end
          handoffs_done << direction
          # "Replay each captured message unchanged after every later handoff."
          [*captures, cross_company].each { |capture| replay.call(capture, direction) }
        end

        run_handoff.call(:cutover)

        # Before rollback: Timekeeping entry API writes and Timekeeping relay deliveries.
        generation = ownership_generation.call
        # A user token lives 60 seconds, so each send carries a fresh token for
        # the same user; the Idempotency-Key, generation, If-Match and body are
        # sent as first recorded.
        api_request = lambda do |method, path, headers, body|
          lambda do
            token = Timekeeping::UserToken.mint(user: owner, company: fork_and_leaf, project_ids: [project.id], private_key:)
            { method:, path:, body:,
              headers: headers.merge("Authorization" => "Bearer #{token}", "Content-Type" => "application/json") }
          end
        end
        api_body = { "project_id" => project.id, "user_id" => owner.id, "work_date" => "2026-01-07", "duration" => 40.0,
                     "source" => "manual", "source_metadata" => {} }
        api_create_note = "api create #{SecureRandom.hex(4)}"
        api_create = api_request.call("POST", "/v1/companies/#{fork_and_leaf.id}/entries",
                                      { "Idempotency-Key" => SecureRandom.uuid, "Ownership-Generation" => generation.to_s },
                                      api_body.merge("note" => api_create_note))
        relay_deliveries = []
        api_entry_id = nil
        api_update_note = "api update #{SecureRandom.hex(4)}"
        api_update = nil
        with_relays_held.call do |timekeeping|
          created = LiveHandoff.send_request(timekeeping_url, api_create.call)
          expect(created.status).to be_between(200, 299), "Timekeeping API create answered #{created.status}"
          created_row = JSON.parse(created.body)
          api_entry_id = created_row.fetch("id")
          api_update = api_request.call("PATCH", "/v1/companies/#{fork_and_leaf.id}/entries/#{api_entry_id}",
                                        { "Idempotency-Key" => SecureRandom.uuid, "Ownership-Generation" => generation.to_s,
                                          "If-Match" => created_row.fetch("version").to_s },
                                        api_body.merge("note" => api_update_note, "duration" => 50.0))
          updated = LiveHandoff.send_request(timekeeping_url, api_update.call)
          expect(updated.status).to be_between(200, 299), "Timekeeping API update answered #{updated.status}"
          timekeeping_receipt.call(api_entry_id, api_create_note)
          timekeeping_receipt.call(api_entry_id, api_update_note)

          # The runtime's Timekeeping relay cannot run while this block holds
          # its lock, so the shared relay code delivers the new outbox rows
          # here, through a recording endpoint, exactly as that relay would.
          source = Object.new
          source.define_singleton_method(:unsent_after) do |position, limit|
            timekeeping.exec_params(
              "SELECT generation, outbox_position, row_to_json(o)::text FROM outbox_snapshots o " \
              "WHERE sent_at IS NULL AND outbox_position > $1 ORDER BY outbox_position LIMIT $2", [position, limit]
            ).values.map do |row_generation, position_value, row_json|
              { "generation" => Integer(row_generation), "outbox_position" => Integer(position_value),
                "entry" => JSON.parse(row_json).slice(*entry_fields) }
            end
          end
          source.define_singleton_method(:mark_sent) do |positions|
            timekeeping.exec_params("UPDATE outbox_snapshots SET sent_at = now() WHERE sent_at IS NULL AND outbox_position = ANY($1::bigint[])",
                                    ["{#{positions.map { |position| Integer(position) }.join(',')}}"])
            nil
          end
          endpoint = TimekeepingRelay::HttpEndpoint.new(url: monolith_url, token: service_token)
          recorder = Object.new
          recorder.define_singleton_method(:deliver) do |batch, idempotency_key:|
            endpoint.deliver(batch, idempotency_key:).tap do |answer|
              relay_deliveries << { batch:, key: idempotency_key, status: answer.status }
            end
          end
          TimekeepingRelay::Relay.new(source:, endpoint: recorder).deliver(limit: Timekeeping::RelayJob::BATCH_SIZE)
        end

        relay_receipt = lambda do |delivery|
          batch = delivery.fetch(:batch)
          batch = JSON.parse(batch) if batch.is_a?(String)
          ids = batch.fetch("snapshots").map { |snapshot| snapshot.fetch("entry").fetch("company_id") }.uniq.sort
          ActiveRecord::Base.uncached { EntrySnapshotReceipt.find_by!(company_ids: ids, actor: "timekeeping", key: delivery.fetch(:key)) }
        end
        expect(relay_deliveries).not_to be_empty
        relay_deliveries.each do |delivery|
          expect(delivery.fetch(:status)).to eq(200)
          relay_receipt.call(delivery)
        end

        timekeeping_verdict = lambda do |entry_id, note|
          lambda do |reply|
            body, = timekeeping_receipt.call(entry_id, note)
            LiveHandoff.replay_verdict(status: reply.status, body: reply.body, expected_body: body,
                                       refusals: LiveHandoff::TIMEKEEPING_REFUSALS)
          end
        end
        captures << { kind: "Timekeeping API create", base_url: timekeeping_url, request: api_create,
                      verdict: timekeeping_verdict.call(api_entry_id, api_create_note) }
        captures << { kind: "Timekeeping API update", base_url: timekeeping_url, request: api_update,
                      verdict: timekeeping_verdict.call(api_entry_id, api_update_note) }
        relay_deliveries.each_with_index do |delivery, index|
          captures << {
            kind: "Timekeeping relay delivery #{index}", base_url: monolith_url,
            request: lambda {
              { method: "POST", path: TimekeepingRelay::HttpEndpoint::DELIVER_PATH, body: delivery.fetch(:batch),
                headers: { "Authorization" => "Bearer #{service_token}", "Idempotency-Key" => delivery.fetch(:key),
                           "Content-Type" => "application/json" } }
            },
            # "a relay delivery is answered from `entry_snapshot_receipts`."
            verdict: lambda { |reply|
              receipt = relay_receipt.call(delivery)
              stored = receipt.response_body.is_a?(String) ? JSON.parse(receipt.response_body) : receipt.response_body
              parsed = begin
                JSON.parse(reply.body)
              rescue JSON::ParserError
                nil
              end
              reply.status == receipt.response_status && parsed == stored ? :answered_from_receipt : :failed
            }
          }
        end

        run_handoff.call(:rollback)

        # Before re-cutover: prepared-store web creates and updates.
        prepared_key = "prepared-create-#{SecureRandom.hex(8)}"
        prepared_create_note = "prepared #{prepared_key}"
        prepared_create = { method: "POST", path: "/api/v1/timesheet_entry", headers: web_headers.call(prepared_key),
                            body: { "project_id" => project.id,
                                    "timesheet_entry" => { "duration" => 22.0, "note" => prepared_create_note,
                                                           "work_date" => "2026-01-09" } } }
        created = LiveHandoff.send_request(monolith_url, prepared_create)
        expect(created.status).to eq(200)
        prepared_entry_id = JSON.parse(created.body).fetch("entry").fetch("id")
        prepared_update_key = "prepared-update-#{SecureRandom.hex(8)}"
        prepared_update_note = "prepared #{prepared_update_key}"
        prepared_update = { method: "PUT", path: "/api/v1/timesheet_entry/#{prepared_entry_id}",
                            headers: web_headers.call(prepared_update_key),
                            body: { "project_id" => project.id,
                                    "timesheet_entry" => { "duration" => 33.0, "note" => prepared_update_note } } }
        expect(LiveHandoff.send_request(monolith_url, prepared_update).status).to eq(200)
        prepared_receipt.call(prepared_entry_id, prepared_create_note)
        prepared_receipt.call(prepared_entry_id, prepared_update_note)

        prepared_verdict = lambda do |note, action|
          lambda do |reply|
            # "Byte equality always uses the persisted receipt, read back at replay time"
            _body, _status, row = prepared_receipt.call(prepared_entry_id, note)
            expected = LiveHandoff.expected_web_reply_from_row(row, company: fork_and_leaf, action:)
            LiveHandoff.replay_verdict(status: reply.status, body: reply.body, expected_body: expected,
                                       refusals: LiveHandoff::MONOLITH_REFUSALS)
          end
        end
        captures << { kind: "prepared-store web create", base_url: monolith_url, request: -> { prepared_create },
                      verdict: prepared_verdict.call(prepared_create_note, :create) }
        captures << { kind: "prepared-store web update", base_url: monolith_url, request: -> { prepared_update },
                      verdict: prepared_verdict.call(prepared_update_note, :update) }

        # The re-cutover's freeze step drains the local outbox once and is
        # refused when the runtime's relay worker holds the relay lock at that
        # moment, so the worker is first given time to deliver these writes,
        # as spec/integration/timekeeping/handoff_sequence_spec.rb waits.
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
        while ActiveRecord::Base.uncached { Timekeeping::LocalOutboxEntry.where(sent_at: nil).exists? }
          raise "the prepared store's outbox was not delivered within 60 s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep 1
        end

        run_handoff.call(:re_cutover)
      end

      expect(handoffs_done).to eq(%i[cutover rollback re_cutover])
    end
  end
end
