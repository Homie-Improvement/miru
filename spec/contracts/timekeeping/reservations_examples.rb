# frozen_string_literal: true

require_relative "contract_example_helpers"

# Prepare, commit and abort, with the mark-billed and detach-entries service
# commands (contracts/timekeeping/reservations.yml), including every section
# 9.3 failure-table row of docs/architecture/timekeeping-soa.md marked
# "Contract" that describes Timekeeping. Needs the timekeeping_client and
# timekeeping_arrange lets.
RSpec.shared_examples "timekeeping reservations contract" do
  include TimekeepingContractExampleHelpers

  let(:company) { timekeeping_arrange.company }
  let(:other_company) { timekeeping_arrange.company }
  let(:service) { timekeeping_arrange.service_identity(company:, name: "invoice-boundary", operations: reservation_operations) }
  let(:conflict_error) { timekeeping_contract_error(:reservations, "conflict") }
  let(:invoice_a) { 501 }
  let(:invoice_b) { 502 }
  let(:user) { timekeeping_arrange.user(company:, role: "employee") }
  let(:project) { timekeeping_arrange.project(company:) }
  let(:x) { timekeeping_arrange.entry(company:, user:, project:) }
  let(:y) { timekeeping_arrange.entry(company:, user:, project:) }
  let(:z) { timekeeping_arrange.entry(company:, user:, project:) }
  let(:foreign_entry) do
    foreign_user = timekeeping_arrange.user(company: other_company, role: "employee")
    timekeeping_arrange.entry(company: other_company, user: foreign_user, project: timekeeping_arrange.project(company: other_company))
  end

  def prepare(invoice_id, entries, operation_id: new_key, disposition: "active", credential: service, generation: nil)
    body = { "invoice_id" => invoice_id, "operation_id" => operation_id, "disposition" => disposition, "entries" => entries }
    body["generation"] = generation if generation
    reservation_command(:prepare, company, credential, body)
  end

  def finish(route, invoice_id, operation_id, credential: service)
    reservation_command(route, company, credential, { "invoice_id" => invoice_id, "operation_id" => operation_id })
  end

  def commit_invoice(invoice_id, entries, disposition: "active")
    operation_id = new_key
    expect(prepare(invoice_id, entries, operation_id:, disposition:).status).to eq(200)
    expect(finish(:commit, invoice_id, operation_id).status).to eq(200)
    operation_id
  end

  def reservation_state(*entry_ids)
    entry_ids.index_with do |entry_id|
      [timekeeping_arrange.entry_locked(entry_id), timekeeping_arrange.reservations_for(entry_id)]
    end
  end

  def held_by(invoice_id, state = "committed")
    [{ "invoice_id" => invoice_id, "state" => state }]
  end

  describe "prepare is all or nothing" do
    it "refuses an entry committed to another active invoice, keeps that reservation and reserves nothing else" do
      commit_invoice(invoice_a, [x])
      before = reservation_state(x, y, z)

      response = prepare(invoice_b, [y, x, z])

      expect(response.status).to eq(409)
      expect(response.body).to eq("reason" => conflict_error.fetch("reason"), "conflicts" => [{ "entry_id" => x, "reason" => "on_another_invoice" }])
      expect(reservation_state(x, y, z)).to eq(before)
      expect(timekeeping_arrange.reservations_for(x)).to eq(held_by(invoice_a))
      expect(timekeeping_arrange.entry_locked(x)).to be(true)
      expect([timekeeping_arrange.entry_locked(y), timekeeping_arrange.entry_locked(z)]).to eq([false, false])
      expect(prepare(invoice_b, [y, z]).status).to eq(200)
    end

    it "refuses an entry held provisionally by another open operation" do
      first_operation = new_key
      expect(prepare(invoice_a, [x], operation_id: first_operation).status).to eq(200)
      before = reservation_state(x, y)

      elsewhere = prepare(invoice_b, [y, x])
      unresolved = prepare(invoice_a, [y])

      expect(elsewhere.status).to eq(409)
      expect(elsewhere.body).to eq("reason" => conflict_error.fetch("reason"), "conflicts" => [{ "entry_id" => x, "reason" => "provisional_elsewhere" }])
      expect(unresolved.status).to eq(409)
      unresolved_error = timekeeping_contract_error(:reservations, "unresolved_operation")
      expect(unresolved.status).to eq(unresolved_error.fetch("status"))
      expect(unresolved.body).to eq("reason" => unresolved_error.fetch("reason"), "operation_id" => first_operation,
                                    "retryable" => unresolved_error.fetch("retryable"))
      expect(reservation_state(x, y)).to eq(before)
    end

    it "answers an entry of another company, or a missing one, as a not_found conflict and reserves nothing" do
      before = reservation_state(x, foreign_entry)

      response = prepare(invoice_a, [x, foreign_entry, TimekeepingContractExampleHelpers::MISSING_ID])

      expect(response.status).to eq(409)
      expect(response.body.fetch("conflicts")).to eq(
        [{ "entry_id" => foreign_entry, "reason" => "not_found" },
         { "entry_id" => TimekeepingContractExampleHelpers::MISSING_ID, "reason" => "not_found" }]
      )
      expect(reservation_state(x, foreign_entry)).to eq(before)
    end

    it "answers a stale generation with stale_generation and reserves nothing" do
      before = reservation_state(x)

      response = prepare(invoice_a, [x], generation: timekeeping_arrange.current_generation - 1)

      expect(response.status).to eq(409)
      expect(response.body).to eq(timekeeping_contract_error(:reservations, "stale_generation").fetch("body"))
      expect(reservation_state(x)).to eq(before)
    end
  end

  describe "a successful prepare" do
    it "reserves the entries provisionally and names the path company for each" do
      operation_id = new_key

      response = prepare(invoice_a, [x, y], operation_id:)

      expect(response.status).to eq(200)
      expect(response.body).to eq(
        "operation_id" => operation_id, "state" => "prepared",
        "entries" => [{ "entry_id" => x, "company_id" => company }, { "entry_id" => y, "company_id" => company }]
      )
      expect(timekeeping_arrange.reservations_for(x)).to eq(held_by(invoice_a, "provisional"))
      expect(timekeeping_arrange.entry_locked(x)).to be(true)
    end
  end

  describe "a prepare for a terminal operation" do
    it "returns committed and adds nothing after commit" do
      operation_id = commit_invoice(invoice_a, [x])
      before = reservation_state(x)

      replay = prepare(invoice_a, [x], operation_id:)

      expect(replay.status).to eq(200)
      expect(replay.body.fetch("state")).to eq("committed")
      expect(reservation_state(x)).to eq(before)
    end

    it "returns aborted and adds nothing after abort" do
      operation_id = new_key
      prepare(invoice_a, [y], operation_id:)
      expect(finish(:abort, invoice_a, operation_id).body).to eq("dropped" => 1)

      replay = prepare(invoice_a, [y], operation_id:)

      expect(replay.status).to eq(200)
      expect(replay.body.fetch("state")).to eq("aborted")
      expect(timekeeping_arrange.reservations_for(y)).to eq([])
      expect(timekeeping_arrange.entry_locked(y)).to be(false)
    end
  end

  describe "commit and abort" do
    it "keeps the first terminal state when commit, abort and commit arrive in that order" do
      operation_id = new_key
      prepare(invoice_a, [x], operation_id:)

      first_commit = finish(:commit, invoice_a, operation_id)
      late_abort = finish(:abort, invoice_a, operation_id)
      second_commit = finish(:commit, invoice_a, operation_id)

      expect(first_commit.body).to eq("reserved" => 1, "released" => 0)
      expect(late_abort.body).to eq("dropped" => 0)
      expect(second_commit.body).to eq(first_commit.body)
      expect(timekeeping_arrange.reservations_for(x)).to eq(held_by(invoice_a))
      expect(timekeeping_arrange.entry_locked(x)).to be(true)
    end

    it "releases at commit an entry the stored desired set dropped, though the commit body names no entries" do
      commit_invoice(invoice_a, [x, y])
      operation_id = new_key
      expect(prepare(invoice_a, [x], operation_id:).status).to eq(200)
      expect(timekeeping_arrange.entry_locked(y)).to be(true)

      response = finish(:commit, invoice_a, operation_id)

      expect(response.body).to eq("reserved" => 0, "released" => 1)
      expect(timekeeping_arrange.reservations_for(y)).to eq([])
      expect(timekeeping_arrange.entry_locked(y)).to be(false)
      expect(timekeeping_arrange.reservations_for(x)).to eq(held_by(invoice_a))
    end

    it "lets a successor take a retained entry, keeping the old reservation until the successor commits" do
      commit_invoice(invoice_a, [x], disposition: "retained")
      operation_id = new_key

      expect(prepare(invoice_b, [x], operation_id:).status).to eq(200)
      expect(timekeeping_arrange.reservations_for(x)).to contain_exactly(*held_by(invoice_a), *held_by(invoice_b, "provisional"))

      expect(finish(:commit, invoice_b, operation_id).body).to eq("reserved" => 1, "released" => 0)
      expect(timekeeping_arrange.reservations_for(x)).to eq(held_by(invoice_b))
    end

    it "drops only this operation's provisional reservations on abort" do
      commit_invoice(invoice_a, [x])
      operation_id = new_key
      expect(prepare(invoice_a, [x, y], operation_id:).status).to eq(200)
      expect(timekeeping_arrange.entry_locked(y)).to be(true)

      expect(finish(:abort, invoice_a, operation_id).body).to eq("dropped" => 1)
      expect(timekeeping_arrange.reservations_for(x)).to eq(held_by(invoice_a))
      expect(timekeeping_arrange.entry_locked(x)).to be(true)
      expect(timekeeping_arrange.reservations_for(y)).to eq([])
      expect(timekeeping_arrange.entry_locked(y)).to be(false)
    end
  end

  describe "the service commands" do
    it "marks billed the entries the invoice holds by committed reservation" do
      commit_invoice(invoice_a, [x, y])

      response = reservation_command(:mark_billed, company, service, { "operation_id" => new_key }, invoice_id: invoice_a)

      expect(response.status).to eq(200)
      expect(response.body).to eq("billed" => 2)
    end

    it "detaches the agent from that company's entries only" do
      agent_id = 77
      2.times { timekeeping_arrange.entry(company:, user:, project:, agent_id:) }
      foreign_user = timekeeping_arrange.user(company: other_company, role: "employee")
      timekeeping_arrange.entry(company: other_company, user: foreign_user, project: timekeeping_arrange.project(company: other_company), agent_id:)
      other_service = timekeeping_arrange.service_identity(company: other_company, name: "agent-destroy", operations: reservation_operations)

      own = reservation_command(:detach_entries, company, service, { "operation_id" => new_key }, agent_id:)
      foreign = reservation_command(:detach_entries, other_company, other_service, { "operation_id" => new_key }, agent_id:)

      expect(own.body).to eq("detached" => 2)
      expect(foreign.body).to eq("detached" => 1)
    end

    it "answers a stale generation on every command with stale_generation and changes nothing" do
      operation_id = new_key
      prepare(invoice_a, [x], operation_id:)
      before = reservation_state(x)
      stale = { "generation" => timekeeping_arrange.current_generation - 1 }
      stale_body = timekeeping_contract_error(:reservations, "stale_generation").fetch("body")

      responses = [
        reservation_command(:commit, company, service, stale.merge("invoice_id" => invoice_a, "operation_id" => operation_id)),
        reservation_command(:abort, company, service, stale.merge("invoice_id" => invoice_a, "operation_id" => operation_id)),
        reservation_command(:mark_billed, company, service, stale.merge("operation_id" => new_key), invoice_id: invoice_a),
        reservation_command(:detach_entries, company, service, stale.merge("operation_id" => new_key), agent_id: 77)
      ]

      expect(responses.map { |response| [response.status, response.body] }).to all(eq([409, stale_body]))
      expect(reservation_state(x)).to eq(before)
    end
  end

  describe "who may call the reservation routes" do
    let(:user_token) { timekeeping_arrange.token_for(timekeeping_arrange.user(company:, role: "owner")) }
    let(:service_without_operations) { timekeeping_arrange.service_identity(company:, name: "reporting", operations: []) }
    let(:other_company_service) do
      timekeeping_arrange.service_identity(company: other_company, name: "invoice-boundary", operations: reservation_operations)
    end

    def command(route, credential)
      operation_id = new_key
      case route
      when "prepare" then prepare(invoice_a, [x], operation_id:, credential:)
      when "commit", "abort" then finish(route, invoice_a, operation_id, credential:)
      when "mark_billed" then reservation_command(:mark_billed, company, credential, { "operation_id" => operation_id }, invoice_id: invoice_a)
      when "detach_entries" then reservation_command(:detach_entries, company, credential, { "operation_id" => operation_id }, agent_id: 77)
      end
    end

    def entry_fields(*entry_ids)
      entry_ids.index_with { |entry_id| timekeeping_arrange.stored_entry(entry_id).slice("bill_status", "agent_id") }
    end

    it "refuses a missing credential, a user token, a service without the operation and another company's service" do
      # Entries mark_billed and detach_entries would change, so a provider
      # that writes before refusing has something to change.
      billable = timekeeping_arrange.reserved_entry(company:, invoice_id: invoice_a, state: "committed")
      agent_entry = timekeeping_arrange.entry(company:, user:, project:, agent_id: 77)
      before = reservation_state(x)
      fields_before = entry_fields(billable, agent_entry)
      expect(fields_before).to eq(
        billable => { "bill_status" => "unbilled", "agent_id" => nil },
        agent_entry => { "bill_status" => "unbilled", "agent_id" => 77 }
      )
      expected = {
        nil => timekeeping_contract_error(:reservations, "unauthorized"),
        user_token => timekeeping_contract_error(:reservations, "forbidden"),
        service_without_operations => timekeeping_contract_error(:reservations, "forbidden"),
        other_company_service => timekeeping_contract_error(:reservations, "not_found")
      }

      reservation_operations.each do |route|
        expected.each do |credential, error|
          response = command(route, credential)

          expect([route, response.status, response.body]).to eq([route, error.fetch("status"), error.fetch("body")])
          expect([route, entry_fields(billable, agent_entry)]).to eq([route, fields_before])
        end
      end
      expect(reservation_state(x)).to eq(before)
    end
  end
end
