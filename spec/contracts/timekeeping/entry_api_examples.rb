# frozen_string_literal: true

require_relative "contract_example_helpers"

# The entry API contract (contracts/timekeeping/entry_api.yml). Needs the
# timekeeping_client and timekeeping_arrange lets.
RSpec.shared_examples "timekeeping entry API contract" do
  include TimekeepingContractExampleHelpers

  let(:entry_api) { TimekeepingContract.load(:entry_api) }
  let(:company) { timekeeping_arrange.company }
  let(:other_company) { timekeeping_arrange.company }
  let(:project) { timekeeping_arrange.project(company:) }
  let(:other_project) { timekeeping_arrange.project(company:) }
  let(:owner) { timekeeping_arrange.user(company:, role: "owner") }
  let(:admin) { timekeeping_arrange.user(company:, role: "admin") }
  let(:employee) { timekeeping_arrange.user(company:, role: "employee") }
  let(:colleague) { timekeeping_arrange.user(company:, role: "employee") }
  let(:owner_token) { timekeeping_arrange.token_for(owner) }
  let(:employee_token) { timekeeping_arrange.token_for(employee) }
  let(:foreign_owner) { timekeeping_arrange.user(company: other_company, role: "owner") }
  let(:foreign_owner_token) { timekeeping_arrange.token_for(foreign_owner) }
  let(:foreign_entry) do
    timekeeping_arrange.entry(company: other_company, user: foreign_owner, project: timekeeping_arrange.project(company: other_company))
  end
  let(:not_found) { timekeeping_contract_error(:entry_api, "not_found") }
  let(:stale_generation) { timekeeping_contract_error(:entry_api, "stale_generation") }

  def entry_path(route, entry_id)
    timekeeping_path(:entry_api, route, company_id: company, entry_id:)
  end

  def write(method, path, token, body = nil, **header_options)
    timekeeping_request(method, path, headers: user_headers(token, **header_options), body:)
  end

  describe "the acting user and the target user_id" do
    it "refuses an employee who names another user and creates nothing" do
      response = create_entry(company, employee_token, entry_body(project:, user_id: colleague))

      expect(response.status).to eq(timekeeping_contract_error(:entry_api, "forbidden").fetch("status"))
      expect(response.body).to eq(timekeeping_contract_error(:entry_api, "forbidden").fetch("body"))
      expect(list_entries(company, owner_token, user_id: colleague).body.fetch("entries")).to be_empty
    end

    it "takes the acting user from the token when an employee omits user_id or names themselves" do
      omitted = create_entry(company, employee_token, entry_body(project:))
      named = create_entry(company, employee_token, entry_body(project:, user_id: employee))

      expect([omitted.status, named.status]).to eq([201, 201])
      expect([omitted.body.fetch("user_id"), named.body.fetch("user_id")]).to eq([employee, employee])
    end

    it "lets an owner and an admin name a user of the same company" do
      [owner, admin].each do |privileged|
        response = create_entry(company, timekeeping_arrange.token_for(privileged), entry_body(project:, user_id: colleague))

        expect(response.status).to eq(201)
        expect(response.body.fetch("user_id")).to eq(colleague)
      end
    end

    it "answers an owner who names a user of another company as it answers a missing user" do
      foreign_user = timekeeping_arrange.user(company: other_company, role: "employee")

      foreign = create_entry(company, owner_token, entry_body(project:, user_id: foreign_user))
      missing = create_entry(company, owner_token, entry_body(project:, user_id: TimekeepingContractExampleHelpers::MISSING_ID))

      expect(foreign.status).to eq(not_found.fetch("status"))
      expect(foreign.body).to eq(missing.body)
      expect(list_entries(company, owner_token).body.fetch("entries")).to be_empty
    end

    it "applies the same target-user rule when an update names a user_id" do
      own_entry = create_entry(company, employee_token, entry_body(project:)).body
      owner_entry = create_entry(company, owner_token, entry_body(project:)).body
      foreign_user = timekeeping_arrange.user(company: other_company, role: "employee")

      refused = write("PATCH", entry_path(:update, own_entry.fetch("id")), employee_token, { "user_id" => colleague })
      foreign = write("PATCH", entry_path(:update, owner_entry.fetch("id")), owner_token, { "user_id" => foreign_user })
      moved = write("PATCH", entry_path(:update, owner_entry.fetch("id")), owner_token, { "user_id" => colleague })

      expect(refused.status).to eq(timekeeping_contract_error(:entry_api, "forbidden").fetch("status"))
      expect([foreign.status, foreign.body]).to eq([not_found.fetch("status"), not_found.fetch("body")])
      expect(show_entry(company, owner_token, own_entry.fetch("id")).body).to eq(own_entry)
      expect(moved.status).to eq(200)
      expect(moved.body.fetch("user_id")).to eq(colleague)
    end

    it "refuses a request with a missing or unknown token and changes nothing" do
      entry_id = timekeeping_arrange.entry(company:, user: owner, project:)
      before = show_entry(company, owner_token, entry_id).body
      unauthorized = timekeeping_contract_error(:entry_api, "unauthorized")

      [nil, "unknown-test-token"].each do |token|
        headers = user_headers(token)
        headers = headers.except("Authorization") if token.nil?
        responses = [
          timekeeping_request("GET", entry_path(:show, entry_id), headers:),
          timekeeping_request("POST", timekeeping_path(:entry_api, :create, company_id: company), headers:, body: entry_body(project:)),
          timekeeping_request("PATCH", entry_path(:update, entry_id), headers:, body: { "note" => "Anonymous" })
        ]

        responses.each do |response|
          expect([response.status, response.body]).to eq([unauthorized.fetch("status"), unauthorized.fetch("body")])
        end
      end
      expect(show_entry(company, owner_token, entry_id).body).to eq(before)
      expect(list_entries(company, owner_token).body.fetch("entries").size).to eq(1)
    end

    it "ignores role and acting-user claims in the body" do
      claimed_role = create_entry(company, employee_token, entry_body(project:, user_id: colleague, role: "owner"))
      claimed_actor = create_entry(company, employee_token, entry_body(project:, acting_user_id: colleague, sub: colleague))

      expect(claimed_role.status).to eq(403)
      expect(claimed_actor.status).to eq(201)
      expect(claimed_actor.body.fetch("user_id")).to eq(employee)
    end
  end

  describe "the entry's agent" do
    it "creates an entry with an agent of the entry's user" do
      own_agent = timekeeping_arrange.agent(company:, user: colleague)

      response = create_entry(company, owner_token, entry_body(project:, user_id: colleague, agent_id: own_agent))

      expect(response.status).to eq(201)
      expect(response.body).to include("user_id" => colleague, "agent_id" => own_agent)
    end

    it "answers another company's agent exactly as an agent that does not exist, and creates nothing" do
      foreign_agent = timekeeping_arrange.agent(company: other_company, user: foreign_owner)

      foreign = create_entry(company, owner_token, entry_body(project:, agent_id: foreign_agent))
      missing = create_entry(company, owner_token, entry_body(project:, agent_id: TimekeepingContractExampleHelpers::MISSING_ID))

      expect([foreign.status, foreign.body]).to eq([not_found.fetch("status"), not_found.fetch("body")])
      expect([missing.status, missing.body]).to eq([foreign.status, foreign.body])
      expect(list_entries(company, owner_token).body.fetch("entries")).to be_empty
    end

    it "refuses a create with a colleague's agent" do
      colleague_agent = timekeeping_arrange.agent(company:, user: colleague)

      response = create_entry(company, owner_token, entry_body(project:, agent_id: colleague_agent))

      expect([response.status, response.body]).to eq([not_found.fetch("status"), not_found.fetch("body")])
      expect(list_entries(company, owner_token).body.fetch("entries")).to be_empty
    end

    it "refuses an update that moves an agent entry to another user and changes nothing" do
      colleague_agent = timekeeping_arrange.agent(company:, user: colleague)
      created = create_entry(company, owner_token, entry_body(project:, user_id: colleague, agent_id: colleague_agent)).body

      response = write("PATCH", entry_path(:update, created.fetch("id")), owner_token, { "user_id" => owner })

      expect([response.status, response.body]).to eq([not_found.fetch("status"), not_found.fetch("body")])
      expect(show_entry(company, owner_token, created.fetch("id")).body).to eq(created)
    end
  end

  describe "request and response shapes" do
    it "answers a create with id, company_id, version and the entry fields" do
      body = entry_body(project:, note: "Sprint planning", proof_url: "https://example.test/run/1",
                                  proof_metadata: { "run" => 1 }, bill_status: "unbilled")
      response = create_entry(company, owner_token, body)

      expect(response.status).to eq(201)
      expect(response.body.keys).to match_array(entry_api.dig("response", "entry_fields"))
      expect(response.body).to include("company_id" => company, "user_id" => owner, "locked" => false)
      expect(response.body.slice(*body.keys)).to eq(body)
      expect(response.body.fetch("id")).to be_a(Integer)
      expect(response.body.fetch("version")).to be_a(Integer)
    end

    it "keeps duration as the unconverted float on create, show and list" do
      created = create_entry(company, owner_token, entry_body(project:, duration: 90.0))
      entry_id = created.body.fetch("id")

      expect(created.body.fetch("duration")).to eql(90.0)
      expect(show_entry(company, owner_token, entry_id).body.fetch("duration")).to eql(90.0)
      expect(list_entries(company, owner_token).body.fetch("entries").map { |entry| entry.fetch("duration") }).to eql([90.0])
    end

    it "shows locked as whether the entry has a reservation" do
      free = timekeeping_arrange.entry(company:, user: owner, project:)
      reserved = timekeeping_arrange.reserved_entry(company:, invoice_id: 501)

      expect(show_entry(company, owner_token, free).body.fetch("locked")).to be(false)
      expect(show_entry(company, owner_token, reserved).body.fetch("locked")).to be(true)

      provisional = timekeeping_arrange.reserved_entry(company:, invoice_id: 502, state: "provisional")
      expect(show_entry(company, owner_token, provisional).body.fetch("locked")).to be(true)
    end

    it "updates an entry and raises its version" do
      created = create_entry(company, owner_token, entry_body(project:)).body

      response = write("PATCH", entry_path(:update, created.fetch("id")), owner_token, { "note" => "Edited" })

      expect(response.status).to eq(200)
      expect(response.body).to include("note" => "Edited", "duration" => 90.0)
      expect(response.body.fetch("version")).to be > created.fetch("version")
    end

    it "answers a stale If-Match with version_conflict and changes nothing" do
      created = create_entry(company, owner_token, entry_body(project:)).body
      headers = user_headers(owner_token).merge("If-Match" => (created.fetch("version") - 1).to_s)

      response = timekeeping_request("PATCH", entry_path(:update, created.fetch("id")), headers:, body: { "note" => "Edited" })

      expect(response.status).to eq(409)
      expect(response.body).to eq(timekeeping_contract_error(:entry_api, "version_conflict").fetch("body"))
      expect(show_entry(company, owner_token, created.fetch("id")).body.fetch("note")).to eq("Design review")
    end

    it "discards an entry on DELETE, after which GET answers not_found" do
      entry_id = create_entry(company, owner_token, entry_body(project:)).body.fetch("id")

      expect(write("DELETE", entry_path(:destroy, entry_id), owner_token).status).to eq(200)
      expect(show_entry(company, owner_token, entry_id).status).to eq(not_found.fetch("status"))
    end

    it "filters the list by user_id, project_id, from and to" do
      timekeeping_arrange.entry(company:, user: owner, project:, work_date: "2026-03-01")
      match = timekeeping_arrange.entry(company:, user: employee, project:, work_date: "2026-03-05")
      timekeeping_arrange.entry(company:, user: employee, project: other_project, work_date: "2026-03-05")
      timekeeping_arrange.entry(company:, user: employee, project:, work_date: "2026-03-20")

      entries = list_entries(company, owner_token, from: "2026-03-02", to: "2026-03-10", user_id: employee, project_id: project)

      expect(entries.body.fetch("entries").map { |entry| entry.fetch("id") }).to eq([match])
    end
  end

  describe "409 stale_generation" do
    let(:entry_id) { timekeeping_arrange.entry(company:, user: owner, project:) }
    let(:stale) { timekeeping_arrange.current_generation - 1 }

    it "refuses every write route with a stale Ownership-Generation and changes nothing" do
      before = show_entry(company, owner_token, entry_id).body
      writes = [
        ["POST", timekeeping_path(:entry_api, :create, company_id: company), entry_body(project:)],
        ["PATCH", entry_path(:update, entry_id), { "note" => "Stale" }],
        ["DELETE", entry_path(:destroy, entry_id), nil],
        ["POST", timekeeping_path(:entry_api, :bulk_move, company_id: company), { "entry_ids" => [entry_id], "project_id" => other_project }],
        ["POST", timekeeping_path(:entry_api, :bulk_delete, company_id: company), { "entry_ids" => [entry_id] }]
      ]

      writes.each do |method, path, body|
        response = write(method, path, owner_token, body, generation: stale)

        expect([method, path, response.status, response.body]).to eq([method, path, stale_generation.fetch("status"), stale_generation.fetch("body")])
      end
      expect(show_entry(company, owner_token, entry_id).body).to eq(before)
      expect(list_entries(company, owner_token).body.fetch("entries").size).to eq(1)
    end
  end

  describe "credentials in an entry body" do
    let(:credential_in_body) { timekeeping_contract_error(:entry_api, "credential_in_body") }

    it "refuses a create that nests the caller's token or a service identity in metadata and creates nothing" do
      service = timekeeping_arrange.service_identity(company:, name: "invoice-boundary", operations: [])
      bodies = [
        entry_body(project:, source_metadata: { "session" => owner_token }),
        entry_body(project:, proof_metadata: { "headers" => { "authorization" => "Bearer #{service}" } })
      ]

      bodies.each do |body|
        response = create_entry(company, owner_token, body)

        expect([response.status, response.body]).to eq([credential_in_body.fetch("status"), credential_in_body.fetch("body")])
      end
      expect(list_entries(company, owner_token).body.fetch("entries")).to be_empty
    end

    it "refuses an update that nests the caller's token in metadata and changes nothing" do
      created = create_entry(company, owner_token, entry_body(project:)).body

      response = write("PATCH", entry_path(:update, created.fetch("id")), owner_token, { "proof_metadata" => { "token" => owner_token } })

      expect([response.status, response.body]).to eq([credential_in_body.fetch("status"), credential_in_body.fetch("body")])
      expect(show_entry(company, owner_token, created.fetch("id")).body).to eq(created)
    end
  end

  describe "the company boundary" do
    it "answers GET, PATCH and DELETE of another company's entry exactly as a missing id" do
      before = show_entry(other_company, foreign_owner_token, foreign_entry).body

      [["GET", :show, nil], ["PATCH", :update, { "note" => "Taken" }], ["DELETE", :destroy, nil]].each do |method, route, body|
        foreign = write(method, entry_path(route, foreign_entry), owner_token, body)
        missing = write(method, entry_path(route, TimekeepingContractExampleHelpers::MISSING_ID), owner_token, body)

        expect([foreign.status, foreign.body]).to eq([not_found.fetch("status"), not_found.fetch("body")])
        expect(foreign.body).to eq(missing.body)
      end
      expect(show_entry(other_company, foreign_owner_token, foreign_entry).body).to eq(before)
    end

    it "answers a path company other than the token's company as not_found, even for that company's own records" do
      foreign_project = timekeeping_arrange.project(company: other_company)
      responses = [
        create_entry(other_company, owner_token, entry_body(project: foreign_project)),
        show_entry(other_company, owner_token, foreign_entry),
        list_entries(other_company, owner_token)
      ]

      responses.each do |response|
        expect([response.status, response.body]).to eq([not_found.fetch("status"), not_found.fetch("body")])
      end
      expect(list_entries(other_company, foreign_owner_token).body.fetch("entries").map { |entry| entry.fetch("id") }).to eq([foreign_entry])
    end

    it "lists only the path company's entries" do
      own = timekeeping_arrange.entry(company:, user: owner, project:)
      foreign_entry

      expect(list_entries(company, owner_token).body.fetch("entries").map { |entry| entry.fetch("id") }).to eq([own])
    end

    it "moves only the path company's entries and reports a foreign id as not_found" do
      own = timekeeping_arrange.entry(company:, user: owner, project:)
      before = show_entry(other_company, foreign_owner_token, foreign_entry).body

      response = write("POST", timekeeping_path(:entry_api, :bulk_move, company_id: company), owner_token,
                       { "entry_ids" => [own, foreign_entry], "project_id" => other_project })

      expect(response.status).to eq(200)
      expect(response.body.fetch("results")).to eq(
        [{ "entry_id" => own, "result" => "moved" }, { "entry_id" => foreign_entry, "result" => "not_found" }]
      )
      expect(show_entry(company, owner_token, own).body.fetch("project_id")).to eq(other_project)
      expect(show_entry(other_company, foreign_owner_token, foreign_entry).body).to eq(before)
    end

    it "deletes only the path company's entries and reports a foreign id as not_found" do
      own = timekeeping_arrange.entry(company:, user: owner, project:)

      response = write("POST", timekeeping_path(:entry_api, :bulk_delete, company_id: company), owner_token,
                       { "entry_ids" => [own, foreign_entry] })

      expect(response.body.fetch("results")).to eq(
        [{ "entry_id" => own, "result" => "deleted" }, { "entry_id" => foreign_entry, "result" => "not_found" }]
      )
      expect(show_entry(company, owner_token, own).status).to eq(not_found.fetch("status"))
      expect(show_entry(other_company, foreign_owner_token, foreign_entry).status).to eq(200)
    end
  end
end
