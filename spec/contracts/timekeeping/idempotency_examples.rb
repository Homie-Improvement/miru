# frozen_string_literal: true

require_relative "contract_example_helpers"

# Idempotency across the three contracts (contracts/timekeeping/idempotency.yml):
# same key and body returns the same answer; same key, new body answers
# idempotency_key_reused; a key or operation id from another company or actor
# does not match. Pass the contracts a provider serves, for example
# it_behaves_like "timekeeping idempotency contract", contracts: [:entry_api].
RSpec.shared_examples "timekeeping idempotency contract" do |contracts: [:entry_api, :reservations, :entry_snapshots]|
  include TimekeepingContractExampleHelpers

  let(:key_reused) { timekeeping_contract_error(:idempotency, "key_reused") }
  let(:company) { timekeeping_arrange.company }
  let(:other_company) { timekeeping_arrange.company }
  let(:project) { timekeeping_arrange.project(company:) }

  if contracts.include?(:entry_api)
    context "with the entry API" do
      let(:employee) { timekeeping_arrange.user(company:, role: "employee") }
      let(:token) { timekeeping_arrange.token_for(employee) }
      let(:owner_token) { timekeeping_arrange.token_for(timekeeping_arrange.user(company:, role: "owner")) }

      it "returns the same answer for the same key and body and creates one entry" do
        key = new_key
        first = create_entry(company, token, entry_body(project:), key:)
        replay = create_entry(company, token, entry_body(project:), key:)

        expect(first.status).to eq(201)
        expect([replay.status, replay.body]).to eq([first.status, first.body])
        expect(list_entries(company, owner_token).body.fetch("entries").size).to eq(1)
      end

      it "answers the same key with a new body with idempotency_key_reused" do
        key = new_key
        create_entry(company, token, entry_body(project:), key:)

        reused = create_entry(company, token, entry_body(project:, note: "Another note"), key:)

        expect([reused.status, reused.body]).to eq([key_reused.fetch("status"), key_reused.fetch("body")])
        expect(list_entries(company, owner_token).body.fetch("entries").size).to eq(1)
      end

      it "does not match the same key and body from another actor of the same company" do
        key = new_key
        first = create_entry(company, token, entry_body(project:), key:)
        colleague = timekeeping_arrange.user(company:, role: "employee")

        other_actor = create_entry(company, timekeeping_arrange.token_for(colleague), entry_body(project:), key:)

        expect(other_actor.status).to eq(201)
        expect(other_actor.body.fetch("id")).not_to eq(first.body.fetch("id"))
        expect(other_actor.body.fetch("user_id")).to eq(colleague)
      end

      it "does not match the same key and body from another company" do
        key = new_key
        create_entry(company, token, entry_body(project:), key:)
        foreign_token = timekeeping_arrange.token_for(timekeeping_arrange.user(company: other_company, role: "owner"))

        # Evaluated afresh, the project of the first company is not found in the other one.
        other_company_answer = create_entry(other_company, foreign_token, entry_body(project:), key:)

        expect(other_company_answer.status).to eq(timekeeping_contract_error(:entry_api, "not_found").fetch("status"))
      end

      it "evaluates a retry after a 409 again instead of replaying the conflict" do
        key = new_key
        stale = timekeeping_request("POST", timekeeping_path(:entry_api, :create, company_id: company),
                                    headers: user_headers(token, generation: timekeeping_arrange.current_generation - 1, key:),
                                    body: entry_body(project:))

        retry_answer = create_entry(company, token, entry_body(project:), key:)

        expect(stale.status).to eq(409)
        expect(retry_answer.status).to eq(201)
      end

      # "a 2xx answer that changed nothing stores no receipt" (idempotency.yml). The same key sent again with a new body
      # shows whether a receipt was stored: a stored one answers
      # idempotency_key_reused, and none lets the new body be evaluated. Every
      # provider answers this way, unlike a replay-only retry, which the local
      # owner refuses at its generation check before it reads any receipt.
      it "stores no receipt for a bulk delete that changed nothing and keeps the receipt of one that did" do
        foreign_user = timekeeping_arrange.user(company: other_company, role: "employee")
        foreign_entry = timekeeping_arrange.entry(company: other_company, user: foreign_user,
                                                  project: timekeeping_arrange.project(company: other_company))
        # Dated today, so an employee's edit window never refuses the delete.
        own_entry = timekeeping_arrange.entry(company:, user: employee, project:, work_date: Date.current.iso8601)
        path = timekeeping_path(:entry_api, :bulk_delete, company_id: company)
        bulk_delete = lambda do |entry_id, key|
          timekeeping_request("POST", path, headers: user_headers(token, key:), body: { "entry_ids" => [entry_id] })
        end

        key = new_key
        unchanged = bulk_delete.call(foreign_entry, key)
        changed = bulk_delete.call(own_entry, key)
        # The entry is discarded now, so only the stored receipt can answer "deleted" again.
        changed_replay = bulk_delete.call(own_entry, key)

        expect([unchanged.status, unchanged.body])
          .to eq([200, { "results" => [{ "entry_id" => foreign_entry, "result" => "not_found" }] }])
        expect([changed.status, changed.body])
          .to eq([200, { "results" => [{ "entry_id" => own_entry, "result" => "deleted" }] }])
        expect([changed_replay.status, changed_replay.body]).to eq([changed.status, changed.body])
      end
    end
  end

  if contracts.include?(:reservations)
    context "with reservation operation ids" do
      let(:operations) { reservation_operations }
      let(:service) { timekeeping_arrange.service_identity(company:, name: "invoice-boundary", operations:) }
      let(:user) { timekeeping_arrange.user(company:, role: "employee") }
      let(:x) { timekeeping_arrange.entry(company:, user:, project:) }
      let(:y) { timekeeping_arrange.entry(company:, user:, project:) }

      # A provider that asks the monolith who owns an invoice refuses an id
      # nobody arranged, so the invoices these examples name are the company's.
      before { [501, 502].each { |invoice_id| timekeeping_arrange.invoice(company:, invoice_id:) } }

      def prepare_with(credential, company_id, invoice_id, entries, operation_id)
        reservation_command(:prepare, company_id, credential,
                            { "invoice_id" => invoice_id, "operation_id" => operation_id, "disposition" => "active", "entries" => entries })
      end

      it "returns the same answer for the same operation id and body and reserves once" do
        operation_id = new_key
        first = prepare_with(service, company, 501, [x], operation_id)
        replay = prepare_with(service, company, 501, [x], operation_id)

        expect(first.status).to eq(200)
        expect([replay.status, replay.body]).to eq([first.status, first.body])
        expect(timekeeping_arrange.reservations_for(x)).to eq([{ "invoice_id" => 501, "state" => "provisional" }])
      end

      it "answers the same operation id with a new entry set with idempotency_key_reused" do
        operation_id = new_key
        prepare_with(service, company, 501, [x], operation_id)

        reused = prepare_with(service, company, 501, [x, y], operation_id)

        expect([reused.status, reused.body]).to eq([key_reused.fetch("status"), key_reused.fetch("body")])
        expect(timekeeping_arrange.reservations_for(y)).to eq([])
      end

      it "does not match an operation id reused by another service of the same company" do
        operation_id = new_key
        prepare_with(service, company, 501, [x], operation_id)
        second_service = timekeeping_arrange.service_identity(company:, name: "invoice-cleanup", operations:)

        other_actor = prepare_with(second_service, company, 502, [y], operation_id)

        expect(other_actor.status).to eq(200)
        expect(other_actor.body.fetch("entries")).to eq([{ "entry_id" => y, "company_id" => company }])
      end

      it "keeps another service's reservations when one service ends an operation with the same id" do
        operation_id = new_key
        second_service = timekeeping_arrange.service_identity(company:, name: "invoice-cleanup", operations:)
        prepare_with(service, company, 501, [x], operation_id)
        prepare_with(second_service, company, 502, [y], operation_id)

        aborted = reservation_command(:abort, company, service, { "invoice_id" => 501, "operation_id" => operation_id })

        expect(aborted.body).to eq("dropped" => 1)
        expect(timekeeping_arrange.reservations_for(x)).to eq([])
        expect(timekeeping_arrange.reservations_for(y)).to eq([{ "invoice_id" => 502, "state" => "provisional" }])

        committed = reservation_command(:commit, company, second_service, { "invoice_id" => 502, "operation_id" => operation_id })

        expect(committed.body).to eq("reserved" => 1, "released" => 0)
        expect(timekeeping_arrange.reservations_for(y)).to eq([{ "invoice_id" => 502, "state" => "committed" }])
      end

      it "does not match an operation id reused by another company" do
        operation_id = new_key
        prepare_with(service, company, 501, [x], operation_id)
        foreign_service = timekeeping_arrange.service_identity(company: other_company, name: "invoice-boundary", operations:)
        foreign_user = timekeeping_arrange.user(company: other_company, role: "employee")
        foreign_entry = timekeeping_arrange.entry(company: other_company, user: foreign_user, project: timekeeping_arrange.project(company: other_company))

        foreign_invoice = timekeeping_arrange.invoice(company: other_company, invoice_id: 601)

        other_company_answer = prepare_with(foreign_service, other_company, foreign_invoice, [foreign_entry], operation_id)

        expect(other_company_answer.status).to eq(200)
        expect(other_company_answer.body.fetch("entries")).to eq([{ "entry_id" => foreign_entry, "company_id" => other_company }])
      end

      it "returns the first answer when the same abort, mark-billed or detach-entries is replayed" do
        abort_operation = new_key
        prepare_with(service, company, 501, [x], abort_operation)
        commit_operation = new_key
        prepare_with(service, company, 502, [y], commit_operation)
        reservation_command(:commit, company, service, { "invoice_id" => 502, "operation_id" => commit_operation })
        timekeeping_arrange.entry(company:, user:, project:, agent_id: 77)
        commands = [
          [:abort, { "invoice_id" => 501, "operation_id" => abort_operation }, {}, { "dropped" => 1 }],
          [:mark_billed, { "operation_id" => new_key }, { invoice_id: 502 }, { "billed" => 1 }],
          [:detach_entries, { "operation_id" => new_key }, { agent_id: 77 }, { "detached" => 1 }]
        ]

        commands.each do |route, body, path_params, expected|
          first = reservation_command(route, company, service, body, **path_params)
          replay = reservation_command(route, company, service, body, **path_params)

          expect([route, first.status, first.body]).to eq([route, 200, expected])
          expect([route, replay.status, replay.body]).to eq([route, 200, expected])
        end
      end

      # "a 2xx answer that changed nothing stores no receipt", so the same
      # mark-billed is evaluated again once the invoice has an entry to bill.
      it "evaluates a mark-billed that billed nothing again under the same operation id" do
        operation_id = new_key
        nothing_to_bill = reservation_command(:mark_billed, company, service, { "operation_id" => operation_id }, invoice_id: 502)
        commit_operation = new_key
        prepare_with(service, company, 502, [y], commit_operation)
        reservation_command(:commit, company, service, { "invoice_id" => 502, "operation_id" => commit_operation })

        billed = reservation_command(:mark_billed, company, service, { "operation_id" => operation_id }, invoice_id: 502)
        replay = reservation_command(:mark_billed, company, service, { "operation_id" => operation_id }, invoice_id: 502)

        expect([nothing_to_bill.status, nothing_to_bill.body]).to eq([200, { "billed" => 0 }])
        expect([billed.status, billed.body]).to eq([200, { "billed" => 1 }])
        expect([replay.status, replay.body]).to eq([200, { "billed" => 1 }])
      end

      # detach_entries is listed in owned_target_stored_operations: its receipt
      # also refuses later writes naming the agent, so a detach of the
      # company's own agent keeps it even when nothing was detached.
      it "replays a detach-entries that detached nothing under the same operation id" do
        own_agent = timekeeping_arrange.agent(company:, user:)
        operation_id = new_key
        nothing_to_detach = reservation_command(:detach_entries, company, service, { "operation_id" => operation_id },
                                                agent_id: own_agent)
        timekeeping_arrange.entry(company:, user:, project:, agent_id: own_agent)

        replay = reservation_command(:detach_entries, company, service, { "operation_id" => operation_id }, agent_id: own_agent)

        expect([nothing_to_detach.status, nothing_to_detach.body]).to eq([200, { "detached" => 0 }])
        expect([replay.status, replay.body]).to eq([200, { "detached" => 0 }])
      end

      # Another company's agent is not an owned target, so a detach naming it
      # that detached nothing stores no receipt, and the same operation id is
      # evaluated again: once the requesting company has an entry naming that
      # agent id, the retry detaches it.
      it "evaluates a detach-entries of another company's agent that detached nothing again" do
        foreign_user = timekeeping_arrange.user(company: other_company, role: "employee")
        foreign_agent = timekeeping_arrange.agent(company: other_company, user: foreign_user)
        operation_id = new_key
        nothing_to_detach = reservation_command(:detach_entries, company, service, { "operation_id" => operation_id },
                                                agent_id: foreign_agent)
        timekeeping_arrange.entry(company:, user:, project:, agent_id: foreign_agent)

        retried = reservation_command(:detach_entries, company, service, { "operation_id" => operation_id },
                                      agent_id: foreign_agent)

        expect([nothing_to_detach.status, nothing_to_detach.body]).to eq([200, { "detached" => 0 }])
        expect([retried.status, retried.body]).to eq([200, { "detached" => 1 }])
      end

      it "returns the first commit's answer when the same commit is replayed" do
        operation_id = new_key
        prepare_with(service, company, 501, [x], operation_id)
        commit_body = { "invoice_id" => 501, "operation_id" => operation_id }

        first = reservation_command(:commit, company, service, commit_body)
        replay = reservation_command(:commit, company, service, commit_body)

        expect([replay.status, replay.body]).to eq([200, first.body])
        expect(first.body).to eq("reserved" => 1, "released" => 0)
      end
    end
  end

  if contracts.include?(:entry_snapshots)
    context "with snapshot deliveries" do
      let(:relay_identity) { timekeeping_arrange.service_identity(company: nil, name: "timekeeping", operations: ["deliver"]) }

      it "returns the first answer when the same key and batch are replayed" do
        key = new_key
        item = snapshot_item(entry_id: 80_001, company:, version: 1)

        first = deliver_snapshots(relay_identity, [item], key:)
        replay = deliver_snapshots(relay_identity, [item], key:)

        expect(first.body).to eq("applied" => 1, "ignored" => 0)
        expect([replay.status, replay.body]).to eq([200, first.body])
      end

      it "answers the same key with a new batch with idempotency_key_reused" do
        key = new_key
        deliver_snapshots(relay_identity, [snapshot_item(entry_id: 80_001, company:, version: 1)], key:)

        reused = deliver_snapshots(relay_identity, [snapshot_item(entry_id: 80_001, company:, version: 2)], key:)

        expect([reused.status, reused.body]).to eq([key_reused.fetch("status"), key_reused.fetch("body")])
        expect(timekeeping_arrange.projected_entry(80_001)).to include("version" => 1)
      end

      it "does not match the same key on another company's batch" do
        key = new_key
        deliver_snapshots(relay_identity, [snapshot_item(entry_id: 80_001, company:, version: 1)], key:)

        other_company_answer = deliver_snapshots(relay_identity, [snapshot_item(entry_id: 80_002, company: other_company, version: 1)], key:)

        expect([other_company_answer.status, other_company_answer.body]).to eq([200, { "applied" => 1, "ignored" => 0 }])
      end

      it "does not match the same key and batch from another service" do
        key = new_key
        item = snapshot_item(entry_id: 80_001, company:, version: 1)
        second_relay = timekeeping_arrange.service_identity(company: nil, name: "timekeeping-standby", operations: ["deliver"])
        deliver_snapshots(relay_identity, [item], key:)

        other_actor = deliver_snapshots(second_relay, [item], key:)

        expect([other_actor.status, other_actor.body]).to eq([200, { "applied" => 0, "ignored" => 1 }])
      end

      it "evaluates a batch again after a 409 under the same key instead of replaying the refusal" do
        key = new_key
        timekeeping_arrange.set_generation(2)

        refused = deliver_snapshots(relay_identity, [snapshot_item(entry_id: 80_001, company:, version: 1, generation: 1)], key:)
        retried = deliver_snapshots(relay_identity, [snapshot_item(entry_id: 80_001, company:, version: 1, generation: 2)], key:)

        expect(refused.status).to eq(timekeeping_contract_error(:entry_snapshots, "stale_generation").fetch("status"))
        expect([retried.status, retried.body]).to eq([200, { "applied" => 1, "ignored" => 0 }])
      end

      it "counts an already stored version under a new key as ignored" do
        item = snapshot_item(entry_id: 80_001, company:, version: 1)
        deliver_snapshots(relay_identity, [item], key: new_key)

        expect(deliver_snapshots(relay_identity, [item], key: new_key).body).to eq("applied" => 0, "ignored" => 1)
      end
    end
  end
end
