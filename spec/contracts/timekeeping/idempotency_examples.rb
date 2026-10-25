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
    end
  end

  if contracts.include?(:reservations)
    context "with reservation operation ids" do
      let(:operations) { reservation_operations }
      let(:service) { timekeeping_arrange.service_identity(company:, name: "invoice-boundary", operations:) }
      let(:user) { timekeeping_arrange.user(company:, role: "employee") }
      let(:x) { timekeeping_arrange.entry(company:, user:, project:) }
      let(:y) { timekeeping_arrange.entry(company:, user:, project:) }

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

        other_company_answer = prepare_with(foreign_service, other_company, 501, [foreign_entry], operation_id)

        expect(other_company_answer.status).to eq(200)
        expect(other_company_answer.body.fetch("entries")).to eq([{ "entry_id" => foreign_entry, "company_id" => other_company }])
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
