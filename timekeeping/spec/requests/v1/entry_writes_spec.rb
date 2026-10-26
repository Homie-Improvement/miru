# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Entry write routes" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  let(:company) { timekeeping_arrange.company }
  let(:project) { timekeeping_arrange.project(company:) }
  let(:other_project) { timekeeping_arrange.project(company:) }
  let(:owner) { timekeeping_arrange.user(company:, role: "owner") }
  let(:admin) { timekeeping_arrange.user(company:, role: "admin") }
  let(:employee) { timekeeping_arrange.user(company:, role: "employee") }
  let(:colleague) { timekeeping_arrange.user(company:, role: "employee") }
  let(:owner_token) { timekeeping_arrange.token_for(owner) }
  let(:employee_token) { timekeeping_arrange.token_for(employee) }
  let(:entry_id) { timekeeping_arrange.entry(company:, user: employee, project:) }
  let(:entries_path) { "/v1/companies/#{company}/entries" }

  def entry_body(**fields)
    { "project_id" => project, "work_date" => "2026-03-02", "duration" => 45.0, "note" => "Review",
      "source" => "manual", "source_metadata" => {} }.merge(fields.transform_keys(&:to_s))
  end

  def write_headers(token, key: SecureRandom.uuid, generation: timekeeping_arrange.current_generation)
    headers = { "Content-Type" => "application/json", "Ownership-Generation" => generation.to_s }
    headers["Authorization"] = "Bearer #{token}" if token
    headers["Idempotency-Key"] = key if key
    headers
  end

  def send_write(method, path, token, body = nil, **header_options)
    process(method, path, params: body && JSON.generate(body), headers: write_headers(token, **header_options))
    response
  end

  # One request per write route, each valid apart from what an example changes.
  def every_route
    [
      [:post, entries_path, entry_body],
      [:patch, "#{entries_path}/#{entry_id}", { "note" => "Edited" }],
      [:delete, "#{entries_path}/#{entry_id}", nil],
      [:post, "#{entries_path}/bulk-move", { "entry_ids" => [entry_id], "project_id" => other_project }],
      [:post, "#{entries_path}/bulk-delete", { "entry_ids" => [entry_id] }]
    ]
  end

  def reason
    response.parsed_body.fetch("reason")
  end

  describe "when the reference facts cannot be read" do
    {
      "the endpoint answers 500" => ->(stub) { stub.to_return(status: 500, body: "") },
      "the endpoint times out" => ->(stub) { stub.to_timeout },
      "the endpoint answers malformed JSON" => ->(stub) { stub.to_return(status: 200, body: "{not json") }
    }.each do |failure, respond|
      it "answers every write route with 503 reference_unavailable and writes nothing when #{failure}" do
        entry_id
        respond.call(WebMock.stub_request(:get, /reference\.test/))
        before = entry_write_counts

        every_route.each do |method, path, body|
          send_write(method, path, employee_token, body)

          expect([method, path, response.status, reason]).to eq([method, path, 503, "reference_unavailable"])
        end
        expect(entry_write_counts).to eq(before)
      end
    end

    it "evaluates a retry with the same key again once the facts can be read" do
      key = SecureRandom.uuid
      outage = WebMock.stub_request(:get, /reference\.test/).to_return(status: 503, body: "")
      expect(send_write(:post, entries_path, employee_token, entry_body, key:).status).to eq(503)

      WebMock.remove_request_stub(outage)
      expect(send_write(:post, entries_path, employee_token, entry_body, key:).status).to eq(201)
    end
  end

  it "answers a validly signed but expired token with 503 on every write route, without reading the facts" do
    entry_id
    now = Time.now.to_i
    expired = JWT.encode({ sub: employee, company_id: company, role: "employee", iat: now - 120, exp: now - 60,
                           jti: SecureRandom.uuid }, TimekeepingProviderArrange.signing_key, "RS256")
    before = entry_write_counts

    every_route.each do |method, path, body|
      send_write(method, path, expired, body)

      expect([method, path, response.status, reason]).to eq([method, path, 503, "reference_unavailable"])
    end
    expect(WebMock).not_to have_requested(:get, /reference\.test/)
    expect(entry_write_counts).to eq(before)
  end

  it "answers a missing or unknown token with 401 on every write route" do
    [nil, "unknown-test-token"].each do |token|
      every_route.each do |method, path, body|
        send_write(method, path, token, body)

        expect([token, method, path, response.status]).to eq([token, method, path, 401])
      end
    end
  end

  it "refuses a write without an Idempotency-Key on every route before reading the facts" do
    entry_id
    before = entry_write_counts

    every_route.each do |method, path, body|
      send_write(method, path, employee_token, body, key: nil)

      expect([method, path, response.status, reason]).to eq([method, path, 422, "idempotency_key_required"])
    end
    expect(WebMock).not_to have_requested(:get, /reference\.test/)
    expect(entry_write_counts).to eq(before)
  end

  describe "a credential in the body" do
    def escape_first_letter(token)
      index = token.index(/[a-z]/)
      "#{token[0...index]}\\u#{format("%04x", token[index].ord)}#{token[(index + 1)..]}"
    end

    # The raw JSON text, with one letter of the credential written as a JSON
    # escape, so only the decoded body holds the credential.
    def send_raw_create(raw_body)
      post entries_path, params: raw_body, headers: write_headers(employee_token)
    end

    it "refuses the caller's token, another user's token and a held credential even when JSON escapes hide them" do
      held = timekeeping_arrange.service_identity(company:, name: "invoice-boundary", operations: [])
      other_token = timekeeping_arrange.token_for(colleague)
      before = entry_write_counts

      [employee_token, other_token, held, provider_service_token].each do |credential|
        raw = JSON.generate(entry_body(proof_metadata: { "token" => "CREDENTIAL" }))
        send_raw_create(raw.sub("CREDENTIAL", escape_first_letter(credential)))

        expect([response.status, reason]).to eq([422, "credential_in_body"])
      end
      send_write(:post, entries_path, employee_token, entry_body(source_metadata: { other_token => "as a key" }))
      expect([response.status, reason]).to eq([422, "credential_in_body"])
      expect(entry_write_counts).to eq(before)
    end
  end

  it "creates an entry from a body without bill_status as unbilled" do
    send_write(:post, entries_path, employee_token, entry_body)

    expect(response.status).to eq(201)
    expect(response.parsed_body).to include("bill_status" => "unbilled", "user_id" => employee, "company_id" => company)
  end

  it "ignores a body company_id and writes to the path company" do
    foreign_company = timekeeping_arrange.company

    send_write(:post, entries_path, owner_token, entry_body(company_id: foreign_company))

    expect(response.status).to eq(201)
    expect(Entry.find(response.parsed_body.fetch("id")).company_id).to eq(company)
    expect(Entry.where(company_id: foreign_company)).to be_empty
  end

  it "stores the user an admin names in the same company, given as a number or a string" do
    admin_token = timekeeping_arrange.token_for(admin)

    [colleague, colleague.to_s].each do |named|
      send_write(:post, entries_path, admin_token, entry_body(user_id: named))

      expect(response.status).to eq(201)
      expect(Entry.find(response.parsed_body.fetch("id")).user_id).to eq(colleague)
    end
  end

  it "refuses an employee who names a colleague with 403 and accepts their own id as a string" do
    send_write(:post, entries_path, employee_token, entry_body(user_id: colleague))
    expect([response.status, reason]).to eq([403, "forbidden"])

    send_write(:post, entries_path, employee_token, entry_body(user_id: employee.to_s))
    expect([response.status, response.parsed_body.fetch("user_id")]).to eq([201, employee])
  end

  it "answers a project the company does not own with 404 and writes nothing" do
    foreign_project = timekeeping_arrange.project(company: timekeeping_arrange.company)

    send_write(:post, entries_path, owner_token, entry_body(project_id: foreign_project))

    expect([response.status, reason]).to eq([404, "not_found"])
    expect(Entry.count).to eq(0)
  end

  it "answers a stale generation with 409, then evaluates a retry with the same key again" do
    key = SecureRandom.uuid
    stale = timekeeping_arrange.current_generation - 1

    expect(send_write(:post, entries_path, employee_token, entry_body, key:, generation: stale).status).to eq(409)
    expect(send_write(:post, entries_path, employee_token, entry_body, key:).status).to eq(201)
  end

  it "does not replay a key used in another company or by another actor" do
    key = SecureRandom.uuid
    first = send_write(:post, entries_path, employee_token, entry_body, key:).parsed_body

    other_company = timekeeping_arrange.company
    other_owner = timekeeping_arrange.user(company: other_company, role: "owner")
    other_project_there = timekeeping_arrange.project(company: other_company)
    send_write(:post, "/v1/companies/#{other_company}/entries", timekeeping_arrange.token_for(other_owner),
               entry_body(project_id: other_project_there), key:)
    expect(response.status).to eq(201)
    expect(response.parsed_body.fetch("id")).not_to eq(first.fetch("id"))

    send_write(:post, entries_path, timekeeping_arrange.token_for(colleague), entry_body, key:)
    expect(response.status).to eq(201)
    expect(response.parsed_body.fetch("user_id")).to eq(colleague)
  end

  it "answers a body of the wrong shape or not JSON with 400 invalid_request and writes nothing" do
    before = entry_write_counts

    send_write(:post, entries_path, employee_token, entry_body(duration: "45"))
    expect([response.status, response.parsed_body]).to eq([400, { "reason" => "invalid_request" }])

    post entries_path, params: "{not json", headers: write_headers(employee_token)
    expect([response.status, response.parsed_body]).to eq([400, { "reason" => "invalid_request" }])
    expect(entry_write_counts).to eq(before)
  end

  it "replays a committed create on retry even after its project is no longer in the reference facts" do
    key = SecureRandom.uuid
    first = send_write(:post, entries_path, employee_token, entry_body, key:)
    first_body = first.body
    WebMock.stub_request(:get, %r{reference\.test/internal/v1/companies/#{company}/reference}).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: JSON.generate(company_id: company, edit_days: 30, users: [{ id: employee, role: "employee" }],
                          projects: [], missing_project_ids: [project], agents: [])
    )

    replay = send_write(:post, entries_path, employee_token, entry_body, key:)
    expect([replay.status, replay.body]).to eq([201, first_body])

    send_write(:post, entries_path, employee_token, entry_body)
    expect([response.status, reason]).to eq([404, "not_found"])
    expect(Entry.count).to eq(1)
  end

  describe "an employee's single-entry change the entry rules refuse" do
    def own_entry(**attributes)
      timekeeping_arrange.entry(company:, user: employee, project:, **attributes)
    end

    def reserved_own_entry
      own_entry.tap do |id|
        Reservation.create!(company_id: company, entry_id: id, invoice_id: 601, state: "committed",
                            disposition: "active", operation_id: SecureRandom.uuid, created_at: Time.current)
      end
    end

    # A reserved entry is refused only for an update: the rules let an
    # employee delete it.
    {
      "a colleague's entry" => [-> { timekeeping_arrange.entry(company:, user: colleague, project:) }, %i[patch delete]],
      "an own billed entry" => [-> { own_entry(bill_status: "billed") }, %i[patch delete]],
      "an own entry outside the edit window" => [-> { own_entry(work_date: "2026-01-02") }, %i[patch delete]],
      "an own reserved entry" => [-> { reserved_own_entry }, %i[patch]]
    }.each do |target, (arrange_entry, methods)|
      methods.each do |method|
        it "answers #{method.upcase} of #{target} with 403 forbidden and writes nothing" do
          id = instance_exec(&arrange_entry)
          before = entry_write_counts

          send_write(method, "#{entries_path}/#{id}", employee_token, method == :patch ? { "note" => "x" } : nil)

          expect([response.status, reason]).to eq([403, "forbidden"])
          expect(entry_write_counts).to eq(before)
        end
      end
    end
  end

  describe "bulk routes" do
    it "reports a colleague's entry as not_found to an employee and writes nothing for it" do
      colleague_entry = timekeeping_arrange.entry(company:, user: colleague, project:)

      send_write(:post, "#{entries_path}/bulk-move", employee_token,
                 { "entry_ids" => [colleague_entry], "project_id" => other_project })

      expect(response.parsed_body.fetch("results")).to eq([{ "entry_id" => colleague_entry, "result" => "not_found" }])
      expect(Entry.find(colleague_entry).project_id).to eq(project)
      expect([AuditEvent.count, OutboxSnapshot.count]).to eq([0, 0])
    end

    it "moves an employee's free entry and skips their reserved one as not_found, writing nothing for it" do
      free = timekeeping_arrange.entry(company:, user: employee, project:)
      reserved = timekeeping_arrange.entry(company:, user: employee, project:)
      Reservation.create!(company_id: company, entry_id: reserved, invoice_id: 501, state: "committed",
                          disposition: "active", operation_id: SecureRandom.uuid, created_at: Time.current)

      send_write(:post, "#{entries_path}/bulk-move", employee_token,
                 { "entry_ids" => [reserved, free], "project_id" => other_project })

      expect(response.parsed_body.fetch("results")).to eq(
        [{ "entry_id" => reserved, "result" => "not_found" }, { "entry_id" => free, "result" => "moved" }]
      )
      expect([Entry.find(free).project_id, Entry.find(reserved).project_id]).to eq([other_project, project])
      expect(AuditEvent.pluck(:entry_id)).to eq([free])
      expect(OutboxSnapshot.pluck(:id)).to eq([free])
    end

    it "refuses the whole request with 403 when one entry is billed and writes nothing" do
      free = timekeeping_arrange.entry(company:, user: employee, project:)
      billed = timekeeping_arrange.entry(company:, user: employee, project:, bill_status: "billed")
      before = entry_write_counts

      send_write(:post, "#{entries_path}/bulk-delete", employee_token, { "entry_ids" => [free, billed] })

      expect([response.status, reason]).to eq([403, "forbidden"])
      expect(entry_write_counts).to eq(before)
    end
  end
end

# Generated by Descant: acceptance tests below.

RSpec.describe "Entry writes carrying a service token" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  it "refuses a user entry write whose note carries an unregistered signed service token" do
    company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    employee_token = timekeeping_arrange.token_for(timekeeping_arrange.user(company:, role: "employee"))
    now = Time.now.to_i
    # Minted with the token key and never registered as a held credential.
    service_token = JWT.encode({ typ: "timekeeping_service", sub: "invoice-boundary", company_id: company,
                                 operations: %w[reservations.prepare], iat: now, exp: now + 300, jti: SecureRandom.uuid },
                               TimekeepingProviderArrange.signing_key, "RS256")
    before_counts = entry_write_counts

    # "An anonymous or user-delegated request never gets it."
    ["copied #{service_token}", "glued#{service_token}tail"].each do |note|
      body = { "project_id" => project, "work_date" => "2026-03-02", "duration" => 45.0, "note" => note,
               "source" => "manual", "source_metadata" => {} }
      post "/v1/companies/#{company}/entries", params: JSON.generate(body),
                                               headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{employee_token}",
                                                          "Ownership-Generation" => timekeeping_arrange.current_generation.to_s,
                                                          "Idempotency-Key" => SecureRandom.uuid }

      expect([response.status, response.parsed_body]).to eq([422, { "reason" => "credential_in_body" }])
    end
    expect(entry_write_counts).to eq(before_counts)
  end
end

RSpec.describe "Entry write routes with an agent of another company" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # The issue: the entry API "still commits any positive agent_id without checking that the agent exists and
  # belongs to the entry's company and user (design rule S7)". entry_api.yml's company_mismatch rule: "An entry
  # or user of another company answers not_found, exactly as a missing id does." A different answer would let
  # a caller probe which agent ids exist in other companies.
  it "answers a foreign-company agent exactly as an agent id that does not exist, and writes nothing" do
    company = timekeeping_arrange.company
    other_company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    employee = timekeeping_arrange.user(company:, role: "employee")
    other_user = timekeeping_arrange.user(company: other_company, role: "employee")
    foreign_agent = timekeeping_arrange.agent(company: other_company, user: other_user)
    missing_agent = foreign_agent + 10_000
    token = timekeeping_arrange.token_for(employee)
    body = { "project_id" => project, "work_date" => "2026-03-02", "duration" => 45.0, "note" => "Review",
             "source" => "manual", "source_metadata" => {} }
    before = entry_write_counts

    answers = [foreign_agent, missing_agent].map do |agent_id|
      post "/v1/companies/#{company}/entries", params: JSON.generate(body.merge("agent_id" => agent_id)),
                                               headers: { "Content-Type" => "application/json",
                                                          "Authorization" => "Bearer #{token}",
                                                          "Idempotency-Key" => SecureRandom.uuid,
                                                          "Ownership-Generation" => timekeeping_arrange.current_generation.to_s }
      [response.status, response.parsed_body]
    end

    expect(answers).to eq([[404, { "reason" => "not_found" }], [404, { "reason" => "not_found" }]])
    expect(entry_write_counts).to eq(before)
  end
end

RSpec.describe "Entry write routes moving an agent entry to another user" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # The issue: the entry API "still commits any positive agent_id without checking that the agent exists and
  # belongs to the entry's company and user (design rule S7)". A body that changes only user_id leaves the
  # stored agent beside a user it does not belong to, so the check must use the pair the write commits.
  it "refuses an update that moves an agent entry to another user without naming the agent" do
    company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    owner = timekeeping_arrange.user(company:, role: "owner")
    employee = timekeeping_arrange.user(company:, role: "employee")
    colleague = timekeeping_arrange.user(company:, role: "employee")
    agent = timekeeping_arrange.agent(company:, user: employee)
    entry_id = timekeeping_arrange.entry(company:, user: employee, project:, agent_id: agent)
    before = entry_write_counts

    patch "/v1/companies/#{company}/entries/#{entry_id}", params: JSON.generate("user_id" => colleague),
                                                          headers: { "Content-Type" => "application/json",
                                                                     "Authorization" => "Bearer #{timekeeping_arrange.token_for(owner)}",
                                                                     "Idempotency-Key" => SecureRandom.uuid,
                                                                     "Ownership-Generation" => timekeeping_arrange.current_generation.to_s }

    expect([response.status, response.parsed_body]).to eq([404, { "reason" => "not_found" }])
    expect(entry_write_counts).to eq(before)
    expect(Entry.find(entry_id).user_id).to eq(employee)
  end
end

RSpec.describe "Entry write routes", "agent ownership on create" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # The entry API must not commit an agent_id "without checking that the agent
  # exists and belongs to the entry's company and user (design rule S7)".
  it "POST answers 404 not_found for a colleague's agent and stores no entry, while the user's own agent is accepted" do
    company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    employee = timekeeping_arrange.user(company:, role: "employee")
    colleague = timekeeping_arrange.user(company:, role: "employee")
    own_agent = timekeeping_arrange.agent(company:, user: employee)
    colleague_agent = timekeeping_arrange.agent(company:, user: colleague)
    token = timekeeping_arrange.token_for(employee)
    headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{token}",
                "Ownership-Generation" => timekeeping_arrange.current_generation.to_s }
    body = { "project_id" => project, "work_date" => "2026-03-02", "duration" => 45.0, "note" => "Review",
             "source" => "manual", "source_metadata" => {} }

    post "/v1/companies/#{company}/entries", params: JSON.generate(body.merge("agent_id" => colleague_agent)),
                                             headers: headers.merge("Idempotency-Key" => SecureRandom.uuid)
    expect(response).to have_http_status(404)
    expect(response.parsed_body).to eq("reason" => "not_found")
    expect(Entry.where(company_id: company).count).to eq(0)
    expect(OutboxSnapshot.count).to eq(0)

    post "/v1/companies/#{company}/entries", params: JSON.generate(body.merge("agent_id" => own_agent)),
                                             headers: headers.merge("Idempotency-Key" => SecureRandom.uuid)
    expect(response).to have_http_status(201)
    expect(response.parsed_body["agent_id"]).to eq(own_agent)
  end
end

RSpec.describe "Entry write routes", "agent ownership on update" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # The issue asks to "refuse an unknown or foreign agent before the write".
  it "PATCH that sets a colleague's agent on an entry answers 404 not_found and leaves the entry unchanged" do
    company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    owner = timekeeping_arrange.user(company:, role: "owner")
    employee = timekeeping_arrange.user(company:, role: "employee")
    colleague = timekeeping_arrange.user(company:, role: "employee")
    colleague_agent = timekeeping_arrange.agent(company:, user: colleague)
    entry_id = timekeeping_arrange.entry(company:, user: employee, project:)
    headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{timekeeping_arrange.token_for(owner)}",
                "Ownership-Generation" => timekeeping_arrange.current_generation.to_s,
                "Idempotency-Key" => SecureRandom.uuid }
    outbox_before = OutboxSnapshot.count
    version_before = Entry.find(entry_id).version

    patch "/v1/companies/#{company}/entries/#{entry_id}",
          params: JSON.generate("agent_id" => colleague_agent), headers: headers

    expect(response).to have_http_status(404)
    expect(response.parsed_body).to eq("reason" => "not_found")
    stored = Entry.find(entry_id)
    expect([stored.agent_id, stored.user_id, stored.version]).to eq([nil, employee, version_before])
    expect(OutboxSnapshot.count).to eq(outbox_before)
  end
end

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Entry write routes" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "it still commits any positive agent_id without checking that the agent
  # exists and belongs to the entry's company and user (design rule S7)."
  it "refuses a create naming a colleague's agent in the same company with 404 not_found and writes nothing" do
    company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    employee = timekeeping_arrange.user(company:, role: "employee")
    colleague = timekeeping_arrange.user(company:, role: "employee")
    colleagues_agent = timekeeping_arrange.agent(company:, user: colleague)
    body = { "project_id" => project, "work_date" => "2026-03-02", "duration" => 45.0, "note" => "Review",
             "source" => "manual", "source_metadata" => {}, "agent_id" => colleagues_agent }
    headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{timekeeping_arrange.token_for(employee)}",
                "Idempotency-Key" => SecureRandom.uuid, "Ownership-Generation" => timekeeping_arrange.current_generation.to_s }
    before = entry_write_counts

    post "/v1/companies/#{company}/entries", params: JSON.generate(body), headers: headers

    expect(response.status).to eq(404)
    expect(response.parsed_body).to eq("reason" => "not_found")
    expect(entry_write_counts).to eq(before)
  end
end

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Entry write routes" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "it still commits any positive agent_id without checking that the agent
  # exists and belongs to the entry's company and user (design rule S7)."
  it "refuses a patch that sets agent_id to a colleague's agent while the entry keeps its user and leaves the entry unchanged" do
    company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    owner = timekeeping_arrange.user(company:, role: "owner")
    colleague = timekeeping_arrange.user(company:, role: "employee")
    colleagues_agent = timekeeping_arrange.agent(company:, user: colleague)
    entry_id = timekeeping_arrange.entry(company:, user: owner, project:)
    headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{timekeeping_arrange.token_for(owner)}",
                "Idempotency-Key" => SecureRandom.uuid, "Ownership-Generation" => timekeeping_arrange.current_generation.to_s }
    before = entry_write_counts

    patch "/v1/companies/#{company}/entries/#{entry_id}", params: JSON.generate("agent_id" => colleagues_agent), headers: headers

    expect(response.status).to eq(404)
    expect(response.parsed_body).to eq("reason" => "not_found")
    expect(entry_write_counts).to eq(before)
    expect(Entry.find(entry_id).agent_id).to be_nil
  end
end

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Entry write routes" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "The entry API now refuses a zero or negative agent_id, but it still
  # commits any positive agent_id without checking that the agent exists and
  # belongs to the entry's company and user (design rule S7)."
  # The shape refusal must stay a 400, not become the new 404 for unknown agents.
  it "still refuses a zero or negative agent_id with 400 before any agent ownership check and writes nothing" do
    company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    employee = timekeeping_arrange.user(company:, role: "employee")
    token = timekeeping_arrange.token_for(employee)
    before = entry_write_counts

    [0, -1].each do |agent_id|
      body = { "project_id" => project, "work_date" => "2026-03-02", "duration" => 45.0, "note" => "Review",
               "source" => "manual", "source_metadata" => {}, "agent_id" => agent_id }
      headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{token}",
                  "Idempotency-Key" => SecureRandom.uuid, "Ownership-Generation" => timekeeping_arrange.current_generation.to_s }

      post "/v1/companies/#{company}/entries", params: JSON.generate(body), headers: headers

      expect([agent_id, response.status]).to eq([agent_id, 400])
    end
    expect(entry_write_counts).to eq(before)
  end
end

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Entry write routes with a foreign agent on create" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # The issue: the entry API "still commits any positive agent_id without checking that the agent
  # exists and belongs to the entry's company and user (design rule S7)". The answer for another
  # company's agent must match the answer for a missing agent, so it reveals nothing about that company.
  it "refuses a create naming another company's agent exactly as one naming no agent, and writes nothing" do
    company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    owner = timekeeping_arrange.user(company:, role: "owner")
    token = timekeeping_arrange.token_for(owner)
    other_company = timekeeping_arrange.company
    other_user = timekeeping_arrange.user(company: other_company, role: "owner")
    foreign_agent = timekeeping_arrange.agent(company: other_company, user: other_user)
    missing_agent = foreign_agent + 100_000
    before = entry_write_counts

    answers = [foreign_agent, missing_agent].map do |agent_id|
      body = { "project_id" => project, "work_date" => "2026-03-02", "duration" => 45.0, "note" => "Review",
               "source" => "manual", "source_metadata" => {}, "agent_id" => agent_id }
      post "/v1/companies/#{company}/entries", params: JSON.generate(body),
        headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{token}",
                   "Idempotency-Key" => SecureRandom.uuid,
                   "Ownership-Generation" => timekeeping_arrange.current_generation.to_s }
      [response.status, response.body]
    end

    expect(answers.first).to eq([404, JSON.generate(reason: "not_found")]).or eq([404, '{"reason":"not_found"}'])
    expect(response.parsed_body).to eq("reason" => "not_found")
    expect(answers.first).to eq(answers.last)
    expect(entry_write_counts).to eq(before)
  end
end

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Entry write routes with a foreign agent on update" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # The issue: the entry API "still commits any positive agent_id without checking that the agent
  # exists and belongs to the entry's company and user (design rule S7)".
  it "refuses an update that sets another company's agent and leaves the entry and outbox untouched" do
    company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    owner = timekeeping_arrange.user(company:, role: "owner")
    entry_id = timekeeping_arrange.entry(company:, user: owner, project:)
    other_company = timekeeping_arrange.company
    other_user = timekeeping_arrange.user(company: other_company, role: "owner")
    foreign_agent = timekeeping_arrange.agent(company: other_company, user: other_user)
    before = entry_write_counts

    patch "/v1/companies/#{company}/entries/#{entry_id}", params: JSON.generate("agent_id" => foreign_agent),
      headers: { "Content-Type" => "application/json",
                 "Authorization" => "Bearer #{timekeeping_arrange.token_for(owner)}",
                 "Idempotency-Key" => SecureRandom.uuid,
                 "Ownership-Generation" => timekeeping_arrange.current_generation.to_s }

    expect(response.status).to eq(404)
    expect(response.parsed_body).to eq("reason" => "not_found")
    expect(Entry.find(entry_id).agent_id).to be_nil
    expect(entry_write_counts).to eq(before)
  end
end

RSpec.describe "Entry write routes with an agent" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # The issue: the API "still commits any positive agent_id without checking
  # that the agent exists and belongs to the entry's company and user (design
  # rule S7)".
  it "POST answers 404 not_found for a same-company agent of another user and 201 for the user's own agent" do
    company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    employee = timekeeping_arrange.user(company:, role: "employee")
    colleague = timekeeping_arrange.user(company:, role: "employee")
    own_agent = timekeeping_arrange.agent(company:, user: employee)
    colleague_agent = timekeeping_arrange.agent(company:, user: colleague)
    headers = lambda do
      { "Content-Type" => "application/json", "Authorization" => "Bearer #{timekeeping_arrange.token_for(employee)}",
        "Ownership-Generation" => timekeeping_arrange.current_generation.to_s, "Idempotency-Key" => SecureRandom.uuid }
    end
    body = { "project_id" => project, "work_date" => "2026-03-02", "duration" => 45.0, "note" => "Review",
             "source" => "manual", "source_metadata" => {} }

    post "/v1/companies/#{company}/entries", params: JSON.generate(body.merge("agent_id" => colleague_agent)), headers: headers.call
    expect(response).to have_http_status(404)
    expect(response.parsed_body).to eq("reason" => "not_found")
    expect(Entry.where(company_id: company).count).to eq(0)

    post "/v1/companies/#{company}/entries", params: JSON.generate(body.merge("agent_id" => own_agent)), headers: headers.call
    expect(response).to have_http_status(201)
    expect(response.parsed_body.fetch("agent_id")).to eq(own_agent)
  end
end

RSpec.describe "Entry write routes moving an agent entry" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # The issue: the API "still commits any positive agent_id without checking
  # that the agent exists and belongs to the entry's company and user (design
  # rule S7)". A body without agent_id still commits the stored agent beside
  # the new user, so the pair is checked.
  it "PATCH that changes only user_id on an agent entry answers 404 not_found and publishes no snapshot" do
    company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    owner = timekeeping_arrange.user(company:, role: "owner")
    colleague = timekeeping_arrange.user(company:, role: "employee")
    owner_agent = timekeeping_arrange.agent(company:, user: owner)
    entry = timekeeping_arrange.entry(company:, user: owner, project:, agent_id: owner_agent)
    snapshots_before = OutboxSnapshot.count
    headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{timekeeping_arrange.token_for(owner)}",
                "Ownership-Generation" => timekeeping_arrange.current_generation.to_s, "Idempotency-Key" => SecureRandom.uuid }

    patch "/v1/companies/#{company}/entries/#{entry}", params: JSON.generate("user_id" => colleague), headers: headers

    expect(response).to have_http_status(404)
    expect(response.parsed_body).to eq("reason" => "not_found")
    expect(Entry.find(entry).user_id).to eq(owner)
    expect(OutboxSnapshot.count).to eq(snapshots_before)
  end
end

RSpec.describe "Entry write routes" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "Timekeeping::EntryCommand or EntryDecision to refuse an unknown or foreign
  # agent before the write." An agent of another company must look like an id
  # that does not exist, so the answer reveals nothing about that company.
  it "answers another company's agent exactly as an agent id that does not exist and writes nothing" do
    company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    employee = timekeeping_arrange.user(company:, role: "employee")
    other_company = timekeeping_arrange.company
    foreign_agent = timekeeping_arrange.agent(company: other_company,
                                              user: timekeeping_arrange.user(company: other_company, role: "employee"))
    body = { "project_id" => project, "work_date" => "2026-03-02", "duration" => 45.0, "note" => "Review",
             "source" => "manual", "source_metadata" => {} }
    headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{timekeeping_arrange.token_for(employee)}",
                "Ownership-Generation" => timekeeping_arrange.current_generation.to_s }
    before = entry_write_counts

    answers = [foreign_agent, 999_999].map do |agent_id|
      post "/v1/companies/#{company}/entries", params: JSON.generate(body.merge("agent_id" => agent_id)),
                                                headers: headers.merge("Idempotency-Key" => SecureRandom.uuid)
      [response.status, response.parsed_body]
    end

    expect(answers).to eq([[404, { "reason" => "not_found" }], [404, { "reason" => "not_found" }]])
    expect(entry_write_counts).to eq(before)
  end
end

RSpec.describe "Entry write routes" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "it still commits any positive agent_id without checking that the agent
  # exists and belongs to the entry's company and user (design rule S7)."
  it "refuses a create naming a same-company agent of another user and writes nothing" do
    company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    employee = timekeeping_arrange.user(company:, role: "employee")
    colleague = timekeeping_arrange.user(company:, role: "employee")
    colleague_agent = timekeeping_arrange.agent(company:, user: colleague)
    body = { "project_id" => project, "work_date" => "2026-03-02", "duration" => 45.0, "note" => "Review",
             "source" => "manual", "source_metadata" => {}, "agent_id" => colleague_agent }
    headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{timekeeping_arrange.token_for(employee)}",
                "Ownership-Generation" => timekeeping_arrange.current_generation.to_s,
                "Idempotency-Key" => SecureRandom.uuid }
    before = entry_write_counts

    post "/v1/companies/#{company}/entries", params: JSON.generate(body), headers: headers

    expect([response.status, response.parsed_body]).to eq([404, { "reason" => "not_found" }])
    expect(entry_write_counts).to eq(before)
  end
end

RSpec.describe "Entry write routes" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "it still commits any positive agent_id without checking that the agent
  # exists and belongs to the entry's company and user (design rule S7)."
  it "refuses an update that sets another user's agent on the entry and leaves it unchanged" do
    company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    employee = timekeeping_arrange.user(company:, role: "employee")
    colleague_agent = timekeeping_arrange.agent(company:, user: timekeeping_arrange.user(company:, role: "employee"))
    entry_id = timekeeping_arrange.entry(company:, user: employee, project:)
    headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{timekeeping_arrange.token_for(employee)}",
                "Ownership-Generation" => timekeeping_arrange.current_generation.to_s,
                "Idempotency-Key" => SecureRandom.uuid }
    before = entry_write_counts

    patch "/v1/companies/#{company}/entries/#{entry_id}", params: JSON.generate("agent_id" => colleague_agent),
                                                           headers: headers

    expect([response.status, response.parsed_body]).to eq([404, { "reason" => "not_found" }])
    expect(entry_write_counts).to eq(before)
    expect(Entry.find(entry_id).agent_id).to be_nil
  end
end

RSpec.describe "Entry write routes" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "The entry API now refuses a zero or negative agent_id" - that shape check
  # must keep answering before the new ownership check, with no write.
  it "still answers a zero or negative agent_id with 400 rather than the new not_found" do
    company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    employee = timekeeping_arrange.user(company:, role: "employee")
    token = timekeeping_arrange.token_for(employee)
    body = { "project_id" => project, "work_date" => "2026-03-02", "duration" => 45.0, "note" => "Review",
             "source" => "manual", "source_metadata" => {} }
    before = entry_write_counts

    statuses = [0, -3].map do |agent_id|
      post "/v1/companies/#{company}/entries", params: JSON.generate(body.merge("agent_id" => agent_id)),
                                                headers: { "Content-Type" => "application/json",
                                                           "Authorization" => "Bearer #{token}",
                                                           "Ownership-Generation" => timekeeping_arrange.current_generation.to_s,
                                                           "Idempotency-Key" => SecureRandom.uuid }
      response.status
    end

    expect(statuses).to eq([400, 400])
    expect(entry_write_counts).to eq(before)
  end
end

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Entry write routes with an agent owned by the acting user" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # The issue: "refuse an unknown or foreign agent before the write". The agent must belong to the
  # entry's user, which is the user the body names, not the acting owner.
  it "refuses an owner's create for an employee that carries the owner's own agent and writes nothing" do
    company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    owner = timekeeping_arrange.user(company:, role: "owner")
    employee = timekeeping_arrange.user(company:, role: "employee")
    owner_agent = timekeeping_arrange.agent(company:, user: owner)
    employee_agent = timekeeping_arrange.agent(company:, user: employee)
    body = { "project_id" => project, "work_date" => "2026-03-02", "duration" => 45.0, "note" => "Review",
             "source" => "manual", "source_metadata" => {}, "user_id" => employee }
    headers = lambda do
      { "Content-Type" => "application/json", "Authorization" => "Bearer #{timekeeping_arrange.token_for(owner)}",
        "Ownership-Generation" => timekeeping_arrange.current_generation.to_s, "Idempotency-Key" => SecureRandom.uuid }
    end
    before = entry_write_counts

    post "/v1/companies/#{company}/entries", params: JSON.generate(body.merge("agent_id" => owner_agent)), headers: headers.call

    expect(response.status).to eq(404)
    expect(response.parsed_body).to eq("reason" => "not_found")
    expect(entry_write_counts).to eq(before)

    post "/v1/companies/#{company}/entries", params: JSON.generate(body.merge("agent_id" => employee_agent)), headers: headers.call

    expect(response.status).to eq(201)
    expect(response.parsed_body.values_at("user_id", "agent_id")).to eq([employee, employee_agent])
  end
end

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Entry write routes updating only agent_id" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # The issue: the entry API commits "any positive agent_id without checking that the agent exists
  # and belongs to the entry's company and user (design rule S7)". The body names no user_id, so the
  # check must use the entry's stored user.
  it "refuses an update that sets agent_id to a colleague's agent while the stored user stays, and writes nothing" do
    company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    owner = timekeeping_arrange.user(company:, role: "owner")
    employee = timekeeping_arrange.user(company:, role: "employee")
    colleague = timekeeping_arrange.user(company:, role: "employee")
    colleague_agent = timekeeping_arrange.agent(company:, user: colleague)
    entry_id = timekeeping_arrange.entry(company:, user: employee, project:)
    before = entry_write_counts

    patch "/v1/companies/#{company}/entries/#{entry_id}",
          params: JSON.generate("agent_id" => colleague_agent),
          headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{timekeeping_arrange.token_for(owner)}",
                     "Ownership-Generation" => timekeeping_arrange.current_generation.to_s,
                     "Idempotency-Key" => SecureRandom.uuid }

    expect(response.status).to eq(404)
    expect(response.parsed_body).to eq("reason" => "not_found")
    expect(entry_write_counts).to eq(before)
    expect(Entry.find(entry_id).agent_id).to be_nil
  end
end

RSpec.describe "Entry write routes on an entry with its user's own agent" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # Writes that keep the agent/user pair valid, or clear the agent, must not
  # be refused by the agent ownership check.
  it "clears the agent with a null agent_id, and moves and deletes agent entries" do
    company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    other_project = timekeeping_arrange.project(company:)
    owner = timekeeping_arrange.user(company:, role: "owner")
    owner_agent = timekeeping_arrange.agent(company:, user: owner)
    cleared, moved, deleted = Array.new(3) { timekeeping_arrange.entry(company:, user: owner, project:, agent_id: owner_agent) }
    headers = lambda do
      { "Content-Type" => "application/json", "Authorization" => "Bearer #{timekeeping_arrange.token_for(owner)}",
        "Ownership-Generation" => timekeeping_arrange.current_generation.to_s, "Idempotency-Key" => SecureRandom.uuid }
    end

    patch "/v1/companies/#{company}/entries/#{cleared}", params: JSON.generate("agent_id" => nil), headers: headers.call
    expect(response.status).to eq(200)
    post "/v1/companies/#{company}/entries/bulk-move",
         params: JSON.generate("entry_ids" => [moved], "project_id" => other_project), headers: headers.call
    expect(response.status).to eq(200)
    expect(response.parsed_body.fetch("results")).to eq([{ "entry_id" => moved, "result" => "moved" }])
    delete "/v1/companies/#{company}/entries/#{deleted}", headers: headers.call
    expect(response.status).to eq(200)

    expect(Entry.find(cleared).agent_id).to be_nil
    expect([Entry.find(moved).project_id, Entry.find(moved).agent_id]).to eq([other_project, owner_agent])
    expect(Entry.find(deleted).discarded_at).not_to be_nil
  end
end
