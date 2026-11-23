# frozen_string_literal: true

require "rails_helper"
require "json"
require "securerandom"
require "yaml"

# A live proof that every pre-handoff write or relay delivery sent again after
# a later cutover, rollback or re-cutover is refused or answered from the
# receipt its first attempt stored, and writes nothing. All three handoffs and
# every capture share one example, because the :integrated_runtime hooks
# empty both databases after every example and each capture must be replayed
# after every later handoff. The :integrated_runtime tag skips it unless the
# live flag is set (spec/support/timekeeping/integrated_runtime.rb), so the
# default suite skips it, and a skip is not a pass.
#
# The same tag turns on the queue ledger
# (spec/support/timekeeping/queue_ledger.rb), so a job any runtime worker runs
# from a non-dedicated queue fails the suite at teardown. The ledger reads only
# Solid Queue rows and cannot see the inline Timekeeping::RelayJob run, so that
# run is wrapped in TimekeepingQueueLedger.inline_performs and every job it
# performs must be on a dedicated monolith queue.
#
# No relay message exists before the first cutover: the legacy store has no
# outbox, and Timekeeping::RelayJob reads only the prepared store's.
RSpec.describe "Timekeeping late replay" do
  context "every owner's captured messages", :integrated_runtime, :two_tenant_seed, committed_data: true,
                                             owner_state: "legacy" do
    it "refuses or answers from receipts every legacy, Timekeeping, prepared-store and relay message and a cross-company create after every later handoff" do
      company_ids = [fork_and_leaf.id, copper_kettle.id]
      monolith_url = @integrated_runtime.monolith_url
      timekeeping_url = @integrated_runtime.timekeeping_url
      service_token = @integrated_runtime.credentials.service_token
      private_key = OpenSSL::PKey::RSA.new(@integrated_runtime.credentials.private_key_pem)
      entry_fields = YAML.safe_load_file(Rails.root.join("contracts/timekeeping/entry_snapshots.yml")).fetch("entry_fields")
      connection = ActiveRecord::Base.connection
      monolith_relay_lock = Timekeeping::RelayJob::RELAY_LOCK_KEY
      owner = User.with_role(:owner, fork_and_leaf).first
      project = fork_and_leaf.projects.kept.first
      intruder = User.with_role(:owner, copper_kettle).first
      web_headers = ->(key) { { "X-Auth-Email" => owner.email, "X-Auth-Token" => owner.token, "Idempotency-Key" => key } }
      handoffs_done = []

      # "Bracket every replay with `LiveHandoff.tenant_counts` for each company in both stores: entries, version sums, `audits`, `entry_audits`, `audit_events`, receipts and outbox. Also compare `TenantStateDigest.take`. Never add the two companies' counts together."
      replay = lambda do |capture, direction|
        label = "#{capture.fetch(:kind)} after #{direction}"
        before, reply, after = with_live_relays_held do
          [live_tenant_states(company_ids), LiveHandoff.send_request(capture.fetch(:base_url), capture.fetch(:request).call),
           live_tenant_states(company_ids)]
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
      # A web write forwarded by the monolith and an entry API write may store
      # their receipts under different actors, so only the company is matched;
      # the entry id and note pick the one receipt.
      timekeeping_receipt = lambda do |entry_id, note|
        rows = TimekeepingLiveHandoff.with_timekeeping_database do |timekeeping|
          timekeeping.exec_params("SELECT body, status FROM idempotency_receipts WHERE company_id = $1",
                                  [fork_and_leaf.id]).values
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
      # A monolith web reply must equal the reply rebuilt from the owner row
      # its receipt stores, read back at replay time.
      owner_row_verdict = lambda do |receipt_for, action|
        lambda do |reply|
          # "Byte equality always uses the persisted receipt, read back at replay time"
          _body, _status, row = receipt_for.call
          expected = LiveHandoff.expected_web_reply_from_row(row, company: fork_and_leaf, action:)
          LiveHandoff.replay_verdict(status: reply.status, body: reply.body, expected_body: expected,
                                     refusals: LiveHandoff::MONOLITH_REFUSALS)
        end
      end
      ownership_generation = lambda do
        TimekeepingOwnership.uncached { TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).generation }
      end

      relay_receipt = lambda do |delivery|
        batch = delivery.fetch(:batch)
        batch = JSON.parse(batch) if batch.is_a?(String)
        ids = batch.fetch("snapshots").map { |snapshot| snapshot.fetch("entry").fetch("company_id") }.uniq.sort
        ActiveRecord::Base.uncached { EntrySnapshotReceipt.find_by!(company_ids: ids, actor: "timekeeping", key: delivery.fetch(:key)) }
      end
      # "a relay delivery is answered from `entry_snapshot_receipts`."
      # The projection renders a stored answer with `render json:`, so the
      # expected bytes are the stored body serialized the same way.
      relay_capture = lambda do |kind, delivery|
        {
          kind:, base_url: monolith_url,
          request: lambda {
            { method: "POST", path: TimekeepingRelay::HttpEndpoint::DELIVER_PATH, body: delivery.fetch(:batch),
              headers: { "Authorization" => "Bearer #{service_token}", "Idempotency-Key" => delivery.fetch(:key),
                         "Content-Type" => "application/json" } }
          },
          verdict: lambda { |reply|
            receipt = relay_receipt.call(delivery)
            expected = receipt.response_body.to_json
            reply.status == receipt.response_status && reply.body.b == expected.b ? :answered_from_receipt : :failed
          }
        }
      end
      recorded_deliveries = lambda do
        relay_deliveries = []
        recorder = lambda do |endpoint|
          Object.new.tap do |wrapper|
            wrapper.define_singleton_method(:deliver) do |batch, idempotency_key:|
              endpoint.deliver(batch, idempotency_key:).tap do |answer|
                relay_deliveries << { batch:, key: idempotency_key, status: answer.status }
              end
            end
          end
        end
        [relay_deliveries, recorder]
      end
      # "Each captured request must first answer 2xx with its receipt present."
      require_delivered = lambda do |deliveries, kind|
        expect(deliveries).not_to be_empty, "no #{kind} was captured"
        deliveries.each do |delivery|
          expect(delivery.fetch(:status)).to eq(200), kind
          relay_receipt.call(delivery)
        end
      end

      captures = []

      # Before cutover: legacy web creates and updates for both companies.
      [fork_and_leaf, copper_kettle].each do |company|
        company_owner = User.with_role(:owner, company).first
        company_project = company.projects.kept.first
        headers = ->(key) { { "X-Auth-Email" => company_owner.email, "X-Auth-Token" => company_owner.token, "Idempotency-Key" => key } }
        scope = { company_id: company.id, actor_kind: "user", actor_id: company_owner.id }
        create_key = "late-create-#{SecureRandom.hex(8)}"
        update_key = "late-update-#{SecureRandom.hex(8)}"
        create = { method: "POST", path: "/api/v1/timesheet_entry", headers: headers.call(create_key),
                   body: { "project_id" => company_project.id,
                           "timesheet_entry" => { "duration" => 30.0, "note" => "late #{create_key}", "work_date" => "2026-01-06" } } }
        created = LiveHandoff.send_request(monolith_url, create)
        # "Each captured request must first answer 2xx with its receipt present."
        expect(created.status).to eq(200), "legacy create, company #{company.id}"
        entry_id = JSON.parse(created.body).fetch("entry").fetch("id")
        update = { method: "PUT", path: "/api/v1/timesheet_entry/#{entry_id}", headers: headers.call(update_key),
                   body: { "project_id" => company_project.id, "timesheet_entry" => { "duration" => 45.0, "note" => "late #{update_key}" } } }
        expect(LiveHandoff.send_request(monolith_url, update).status).to eq(200), "legacy update, company #{company.id}"
        create_receipt = -> { ActiveRecord::Base.uncached { Timekeeping::LegacyCreateReceipt.find_by!(**scope, key: create_key) } }
        update_receipt = lambda do
          ActiveRecord::Base.uncached { Timekeeping::LegacyEntryWriteReceipt.find_by!(**scope, key: update_key, operation: "update") }
        end
        create_receipt.call
        update_receipt.call
        legacy_verdict = lambda do |receipt_for, action|
          lambda do |reply|
            expected = LiveHandoff.expected_web_reply(receipt_for.call.entry_attributes, action:)
            LiveHandoff.replay_verdict(status: reply.status, body: reply.body, expected_body: expected,
                                       refusals: LiveHandoff::MONOLITH_REFUSALS)
          end
        end
        captures << { kind: "legacy create, company #{company.id}", base_url: monolith_url, request: -> { create },
                      verdict: legacy_verdict.call(create_receipt, :create) }
        # "A replayed pre-handoff legacy-store update after cutover writes nothing again (no new version, no audit row): it is refused or answered without a second write, not left out"
        captures << { kind: "legacy update, company #{company.id}", base_url: monolith_url, request: -> { update },
                      verdict: legacy_verdict.call(update_receipt, :update) }
      end

      # Company B (Fork & Leaf) writes a legacy web create before cutover.
      cross_key = "cross-#{SecureRandom.hex(8)}"
      cross_create = { method: "POST", path: "/api/v1/timesheet_entry", headers: web_headers.call(cross_key),
                       body: { "project_id" => project.id,
                               "timesheet_entry" => { "duration" => 15.0, "note" => "cross #{cross_key}", "work_date" => "2026-01-05" } } }
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

        # Before rollback: web writes through the monolith while Timekeeping
        # owns, Timekeeping entry API writes and Timekeeping relay deliveries.
        tk_web_key = "tk-create-#{SecureRandom.hex(8)}"
        tk_web_create_note = "while Timekeeping owns #{tk_web_key}"
        tk_web_create = { method: "POST", path: "/api/v1/timesheet_entry", headers: web_headers.call(tk_web_key),
                          body: { "project_id" => project.id,
                                  "timesheet_entry" => { "duration" => 25.0, "note" => tk_web_create_note, "work_date" => "2026-01-08" } } }
        created = LiveHandoff.send_request(monolith_url, tk_web_create)
        expect(created.status).to eq(200)
        tk_web_entry_id = JSON.parse(created.body).fetch("entry").fetch("id")
        tk_web_update_key = "tk-update-#{SecureRandom.hex(8)}"
        tk_web_update_note = "updated while Timekeeping owns #{tk_web_update_key}"
        tk_web_update = { method: "PUT", path: "/api/v1/timesheet_entry/#{tk_web_entry_id}", headers: web_headers.call(tk_web_update_key),
                          body: { "project_id" => project.id, "timesheet_entry" => { "duration" => 35.0, "note" => tk_web_update_note } } }
        expect(LiveHandoff.send_request(monolith_url, tk_web_update).status).to eq(200)
        timekeeping_receipt.call(tk_web_entry_id, tk_web_create_note)
        timekeeping_receipt.call(tk_web_entry_id, tk_web_update_note)
        # "A web write accepted while Timekeeping owns, replayed unchanged through the monolith after rollback, writes nothing"
        captures << { kind: "web create while Timekeeping owns", base_url: monolith_url, request: -> { tk_web_create },
                      verdict: owner_row_verdict.call(-> { timekeeping_receipt.call(tk_web_entry_id, tk_web_create_note) }, :create) }
        captures << { kind: "web update while Timekeeping owns", base_url: monolith_url, request: -> { tk_web_update },
                      verdict: owner_row_verdict.call(-> { timekeeping_receipt.call(tk_web_entry_id, tk_web_update_note) }, :update) }

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
        timekeeping_deliveries, timekeeping_recorder = recorded_deliveries.call
        api_entry_id = nil
        api_update_note = "api update #{SecureRandom.hex(4)}"
        api_update = nil
        with_live_relays_held do |timekeeping|
          api_created = LiveHandoff.send_request(timekeeping_url, api_create.call)
          expect(api_created.status).to be_between(200, 299), "Timekeeping API create answered #{api_created.status}"
          created_row = JSON.parse(api_created.body)
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
          # its lock, and its delivery cannot be recorded from this process.
          # The shared relay code therefore delivers the new outbox rows here,
          # through a recording endpoint, from a source that reads
          # outbox_snapshots by SQL. That source is not the Timekeeping app's
          # RelayOutboxSource: it writes timestamps and numbers as Postgres
          # renders them, and it does not skip a held generation, so the batch
          # bytes and key can differ from the runtime relay's. What this proves
          # is that a batch the projection accepted and stored a receipt for is
          # answered from that receipt when sent again.
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
          TimekeepingRelay::Relay.new(source:, endpoint: timekeeping_recorder.call(endpoint))
                                 .deliver(limit: Timekeeping::RelayJob::BATCH_SIZE)
        end
        require_delivered.call(timekeeping_deliveries, "Timekeeping relay delivery")

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
        timekeeping_deliveries.each_with_index do |delivery, index|
          captures << relay_capture.call("Timekeeping relay delivery #{index}", delivery)
        end

        run_handoff.call(:rollback)

        # Before re-cutover: prepared-store web creates and updates, and the
        # Timekeeping::RelayJob deliveries that carry them. The monolith relay
        # lock is taken before the writes, so the runtime's own relay worker
        # cannot deliver them before the recorded job run does.
        prepared_key = "prepared-create-#{SecureRandom.hex(8)}"
        prepared_create_note = "prepared #{prepared_key}"
        prepared_create = { method: "POST", path: "/api/v1/timesheet_entry", headers: web_headers.call(prepared_key),
                            body: { "project_id" => project.id,
                                    "timesheet_entry" => { "duration" => 22.0, "note" => prepared_create_note,
                                                           "work_date" => "2026-01-09" } } }
        prepared_update_key = "prepared-update-#{SecureRandom.hex(8)}"
        prepared_update_note = "prepared #{prepared_update_key}"
        prepared_entry_id = nil
        prepared_update = nil
        prepared_deliveries, prepared_recorder = recorded_deliveries.call
        connection.select_value("SELECT pg_advisory_lock(#{monolith_relay_lock})")
        begin
          created = LiveHandoff.send_request(monolith_url, prepared_create)
          expect(created.status).to eq(200)
          prepared_entry_id = JSON.parse(created.body).fetch("entry").fetch("id")
          prepared_update = { method: "PUT", path: "/api/v1/timesheet_entry/#{prepared_entry_id}",
                              headers: web_headers.call(prepared_update_key),
                              body: { "project_id" => project.id,
                                      "timesheet_entry" => { "duration" => 33.0, "note" => prepared_update_note } } }
          expect(LiveHandoff.send_request(monolith_url, prepared_update).status).to eq(200)
          prepared_receipt.call(prepared_entry_id, prepared_create_note)
          prepared_receipt.call(prepared_entry_id, prepared_update_note)

          configured = Timekeeping::LocalSnapshotEndpoint.method(:configured)
          with_timekeeping_env(Timekeeping::LocalSnapshotEndpoint::PROJECTION_URL_ENV => monolith_url) do
            allow(Timekeeping::LocalSnapshotEndpoint).to receive(:configured) { prepared_recorder.call(configured.call) }
            # The job takes the same session lock again on this connection, which Postgres allows.
            relay_queues = TimekeepingQueueLedger.inline_performs { Timekeeping::RelayJob.perform_now }
            expect(TimekeepingQueueLedger.non_dedicated_queues(relay_queues, database: "monolith")).to eq([])
          end
          RSpec::Mocks.space.proxy_for(Timekeeping::LocalSnapshotEndpoint).reset
        ensure
          connection.select_value("SELECT pg_advisory_unlock(#{monolith_relay_lock})")
        end
        require_delivered.call(prepared_deliveries, "prepared-store relay delivery")

        captures << { kind: "prepared-store web create", base_url: monolith_url, request: -> { prepared_create },
                      verdict: owner_row_verdict.call(-> { prepared_receipt.call(prepared_entry_id, prepared_create_note) }, :create) }
        captures << { kind: "prepared-store web update", base_url: monolith_url, request: -> { prepared_update },
                      verdict: owner_row_verdict.call(-> { prepared_receipt.call(prepared_entry_id, prepared_update_note) }, :update) }
        prepared_deliveries.each_with_index do |delivery, index|
          captures << relay_capture.call("prepared-store relay delivery #{index}", delivery)
        end

        # The re-cutover's freeze step drains the local outbox once and is
        # refused when the runtime's relay worker holds the relay lock at that
        # moment, so any rows the recorded job run left are first given time
        # to be delivered, as spec/integration/timekeeping/handoff_sequence_spec.rb waits.
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
