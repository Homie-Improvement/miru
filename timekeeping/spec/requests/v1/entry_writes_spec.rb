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

    # "An anonymous or user-delegated request never gets it."
    it "refuses the provider's service token copied into a note or glued between other text, and writes nothing" do
      before = entry_write_counts

      ["copied #{provider_service_token}", "glued#{provider_service_token}tail"].each do |note|
        send_write(:post, entries_path, employee_token, entry_body(note:))

        expect([note, response.status, reason]).to eq([note, 422, "credential_in_body"])
      end
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
RSpec.describe "Entry write routes", "agent run identifiers" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  let(:run_company) { timekeeping_arrange.company }
  let(:run_project) { timekeeping_arrange.project(company: run_company) }
  let(:run_employee) { timekeeping_arrange.user(company: run_company, role: "employee") }
  let(:run_agent) { timekeeping_arrange.agent(company: run_company, user: run_employee) }

  # "A forwarded agent create with `external_run_id: "run_123"` and `external_session_id: "session_123"` stores both, and both appear in the snapshot."
  it "stores an agent create's run and session ids on the entry and its outbox snapshot, and a retry with the same key writes nothing more" do
    body = { "project_id" => run_project, "work_date" => "2026-03-02", "duration" => 60.0, "note" => "Agent run",
             "source" => "automation", "source_metadata" => {}, "agent_id" => run_agent,
             "external_run_id" => "run_123", "external_session_id" => "session_123" }
    headers = { "Content-Type" => "application/json",
                "Authorization" => "Bearer #{timekeeping_arrange.token_for(run_employee)}",
                "Ownership-Generation" => timekeeping_arrange.current_generation.to_s,
                "Idempotency-Key" => SecureRandom.uuid }

    post "/v1/companies/#{run_company}/entries", params: JSON.generate(body), headers: headers

    expect(response.status).to eq(201)
    answer = response.parsed_body
    expect(answer.values_at("external_run_id", "external_session_id")).to eq(%w[run_123 session_123])
    entry_id = answer.fetch("id")
    expect(Entry.find(entry_id).attributes.values_at("external_run_id", "external_session_id"))
      .to eq(%w[run_123 session_123])
    expect(OutboxSnapshot.where(id: entry_id).pluck(:external_run_id, :external_session_id))
      .to eq([%w[run_123 session_123]])

    counts_after_first = entry_write_counts
    post "/v1/companies/#{run_company}/entries", params: JSON.generate(body), headers: headers

    expect(response.status).to eq(201)
    expect(response.parsed_body).to eq(answer)
    expect(entry_write_counts).to eq(counts_after_first)
    expect(OutboxSnapshot.where(id: entry_id).count).to eq(1)
  end
end

# The entry API must not commit an agent_id "without checking that the agent
# exists and belongs to the entry's company and user (design rule S7)". Every
# refusal answers 404 not_found and writes nothing.
RSpec.describe "Entry write routes", "agent ownership" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  let(:agent_company) { timekeeping_arrange.company }
  let(:agent_project) { timekeeping_arrange.project(company: agent_company) }
  let(:agent_owner) { timekeeping_arrange.user(company: agent_company, role: "owner") }
  let(:agent_employee) { timekeeping_arrange.user(company: agent_company, role: "employee") }
  let(:agent_colleague) { timekeeping_arrange.user(company: agent_company, role: "employee") }
  let(:colleague_agent) { timekeeping_arrange.agent(company: agent_company, user: agent_colleague) }
  let(:agent_entries_path) { "/v1/companies/#{agent_company}/entries" }

  def agent_entry_body(**fields)
    { "project_id" => agent_project, "work_date" => "2026-03-02", "duration" => 45.0, "note" => "Review",
      "source" => "manual", "source_metadata" => {} }.merge(fields.transform_keys(&:to_s))
  end

  def agent_write_headers(user)
    { "Content-Type" => "application/json", "Authorization" => "Bearer #{timekeeping_arrange.token_for(user)}",
      "Ownership-Generation" => timekeeping_arrange.current_generation.to_s, "Idempotency-Key" => SecureRandom.uuid }
  end

  def expect_agent_not_found
    expect([response.status, response.parsed_body]).to eq([404, { "reason" => "not_found" }])
  end

  # The shared entry API contract examples, run against this provider by
  # timekeeping/spec/contracts/entry_provider_spec.rb, own the foreign-versus-missing,
  # colleague-agent and user-only-update refusals; the writer spec owns their
  # row counts. These cases cover what those do not.

  # The agent must belong to the entry's user, which is the user the body names, not the acting owner.
  it "refuses an owner's create for an employee that carries the owner's own agent, and accepts the employee's agent" do
    owner_agent = timekeeping_arrange.agent(company: agent_company, user: agent_owner)
    employee_agent = timekeeping_arrange.agent(company: agent_company, user: agent_employee)
    before = entry_write_counts

    post agent_entries_path, params: JSON.generate(agent_entry_body(user_id: agent_employee, agent_id: owner_agent)),
                             headers: agent_write_headers(agent_owner)
    expect_agent_not_found
    expect(entry_write_counts).to eq(before)

    post agent_entries_path, params: JSON.generate(agent_entry_body(user_id: agent_employee, agent_id: employee_agent)),
                             headers: agent_write_headers(agent_owner)
    expect(response.status).to eq(201)
    expect(response.parsed_body.values_at("user_id", "agent_id")).to eq([agent_employee, employee_agent])
  end

  # The body names no user_id, so the check must use the entry's stored user.
  it "refuses an update that sets a colleague's agent while the stored user stays, and leaves the entry unchanged" do
    entry_id = timekeeping_arrange.entry(company: agent_company, user: agent_employee, project: agent_project)
    version_before = Entry.find(entry_id).version
    before = entry_write_counts

    patch "#{agent_entries_path}/#{entry_id}", params: JSON.generate("agent_id" => colleague_agent),
                                               headers: agent_write_headers(agent_owner)

    expect_agent_not_found
    expect(entry_write_counts).to eq(before)
    stored = Entry.find(entry_id)
    expect([stored.agent_id, stored.user_id, stored.version]).to eq([nil, agent_employee, version_before])
  end

  it "refuses an update that sets another company's agent and leaves the entry untouched" do
    entry_id = timekeeping_arrange.entry(company: agent_company, user: agent_owner, project: agent_project)
    other_company = timekeeping_arrange.company
    foreign_agent = timekeeping_arrange.agent(company: other_company,
                                              user: timekeeping_arrange.user(company: other_company, role: "owner"))
    before = entry_write_counts

    patch "#{agent_entries_path}/#{entry_id}", params: JSON.generate("agent_id" => foreign_agent),
                                               headers: agent_write_headers(agent_owner)

    expect_agent_not_found
    expect(Entry.find(entry_id).agent_id).to be_nil
    expect(entry_write_counts).to eq(before)
  end

  # "The entry API now refuses a zero or negative agent_id": that shape refusal must stay a 400,
  # answered before the ownership check, not become the new 404 for unknown agents.
  it "still refuses a zero or negative agent_id with 400 and writes nothing" do
    before = entry_write_counts

    statuses = [0, -1, -3].map do |agent_id|
      post agent_entries_path, params: JSON.generate(agent_entry_body(agent_id:)), headers: agent_write_headers(agent_employee)
      response.status
    end

    expect(statuses).to eq([400, 400, 400])
    expect(entry_write_counts).to eq(before)
  end

  # Writes that keep the agent/user pair valid, or clear the agent, must not
  # be refused by the agent ownership check.
  it "clears the agent with a null agent_id, and moves and deletes agent entries" do
    other_project = timekeeping_arrange.project(company: agent_company)
    owner_agent = timekeeping_arrange.agent(company: agent_company, user: agent_owner)
    cleared, moved, deleted = Array.new(3) do
      timekeeping_arrange.entry(company: agent_company, user: agent_owner, project: agent_project, agent_id: owner_agent)
    end

    patch "#{agent_entries_path}/#{cleared}", params: JSON.generate("agent_id" => nil), headers: agent_write_headers(agent_owner)
    expect(response.status).to eq(200)
    post "#{agent_entries_path}/bulk-move", params: JSON.generate("entry_ids" => [moved], "project_id" => other_project),
                                            headers: agent_write_headers(agent_owner)
    expect(response.status).to eq(200)
    expect(response.parsed_body.fetch("results")).to eq([{ "entry_id" => moved, "result" => "moved" }])
    delete "#{agent_entries_path}/#{deleted}", headers: agent_write_headers(agent_owner)
    expect(response.status).to eq(200)

    expect(Entry.find(cleared).agent_id).to be_nil
    expect([Entry.find(moved).project_id, Entry.find(moved).agent_id]).to eq([other_project, owner_agent])
    expect(Entry.find(deleted).discarded_at).not_to be_nil
  end
end

RSpec.describe "Entry write routes, replay-only delete" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  let(:company) { timekeeping_arrange.company }
  let(:project) { timekeeping_arrange.project(company:) }
  let(:owner) { timekeeping_arrange.user(company:, role: "owner") }
  let(:admin) { timekeeping_arrange.user(company:, role: "admin") }
  let(:employee) { timekeeping_arrange.user(company:, role: "employee") }
  let(:replay_not_found) { [404, { "reason" => "not_found" }] }

  # company_id lets a caller of another company send its own token to its own
  # company's URL; a token whose company differs from the URL is refused
  # before the receipt lookup runs, so that request would prove nothing.
  def replay_only_delete_request(entry_id, token, key:, company_id: company, replay_only: true, if_match: "replay-only")
    headers = { "Authorization" => "Bearer #{token}", "Idempotency-Key" => key,
                "Ownership-Generation" => timekeeping_arrange.current_generation.to_s, "If-Match" => if_match }
    headers["Idempotency-Replay"] = "only" if replay_only
    delete "/v1/companies/#{company_id}/entries/#{entry_id}", headers: headers.compact
    response
  end

  # "Address this in follow-up design work with an authenticated replay path; do not treat every missing entry as a successful delete."
  # "Replaying it needs a separate design that keeps the lookup-then-authorize order, and nothing is deleted twice meanwhile."
  it "answers an admin's replay-only DELETE of a colleague's kept entry with no receipt as not found and writes nothing" do
    entry_id = timekeeping_arrange.entry(company:, user: employee, project:)
    before = entry_write_counts

    answer = replay_only_delete_request(entry_id, timekeeping_arrange.token_for(admin), key: SecureRandom.uuid,
                                                                                       if_match: nil)

    expect([answer.status, answer.parsed_body]).to eq(replay_not_found)
    expect(Entry.find(entry_id).discarded_at).to be_nil
    expect(entry_write_counts).to eq(before)
  end

  it "answers a replay-only delete with no stored receipt with not_found and changes no entry, audit, outbox or receipt row" do
    entry_id = timekeeping_arrange.entry(company:, user: employee, project:)
    token = timekeeping_arrange.token_for(owner)
    before = entry_write_counts
    expect(before).to include(entries: 1, idempotency_receipts: 0)

    ["replay-only", nil].each do |if_match|
      answer = replay_only_delete_request(entry_id, token, key: SecureRandom.uuid, if_match:)

      expect([answer.status, answer.parsed_body]).to eq(replay_not_found), "If-Match #{if_match.inspect}"
      expect(entry_write_counts).to eq(before)
      expect(Entry.find(entry_id).discarded_at).to be_nil
    end
  end

  # "Allow delete retries to reach the stored answer."
  it "answers an owner's replay-only delete retry with the first delete's stored answer and writes nothing more" do
    entry_id = timekeeping_arrange.entry(company:, user: employee, project:)
    token = timekeeping_arrange.token_for(owner)
    key = SecureRandom.uuid
    first = replay_only_delete_request(entry_id, token, key:, replay_only: false, if_match: nil)
    first_status = first.status
    first_body = first.parsed_body
    after_first = entry_write_counts

    replay = replay_only_delete_request(entry_id, token, key:)

    expect(first_status).to eq(200)
    expect([replay.status, replay.parsed_body]).to eq([first_status, first_body])
    expect(entry_write_counts).to eq(after_first)
  end

  it "answers a replay-only DELETE with not_found for another company reusing the key and for a key with no receipt, discarding nothing" do
    deleted_id = timekeeping_arrange.entry(company:, user: employee, project:)
    kept_id = timekeeping_arrange.entry(company:, user: employee, project:)
    key = SecureRandom.uuid
    first = replay_only_delete_request(deleted_id, timekeeping_arrange.token_for(employee), key:, replay_only: false,
                                                                                              if_match: nil)
    expect(first.status).to eq(200)
    after_first = entry_write_counts

    # Another company's owner, sending the same key for the same entry id, must not reach the stored answer.
    foreign_company = timekeeping_arrange.company
    foreign_owner = timekeeping_arrange.user(company: foreign_company, role: "owner")
    foreign = replay_only_delete_request(deleted_id, timekeeping_arrange.token_for(foreign_owner), key:,
                                                                                                  company_id: foreign_company)
    expect([foreign.status, foreign.parsed_body]).to eq(replay_not_found)
    expect(entry_write_counts).to eq(after_first)

    # A replay-only DELETE with no receipt behind it is answered from nothing and discards nothing, even for a kept entry.
    no_receipt = replay_only_delete_request(kept_id, timekeeping_arrange.token_for(owner), key: SecureRandom.uuid)
    expect([no_receipt.status, no_receipt.parsed_body]).to eq(replay_not_found)
    expect(Entry.find(kept_id).discarded_at).to be_nil
    expect(entry_write_counts).to eq(after_first)
  end

  # A provider that does not read Idempotency-Replay sees an ordinary DELETE;
  # the If-Match value never matches a version, so it refuses without writing.
  it "refuses a DELETE whose If-Match is replay-only with version_conflict and discards nothing" do
    entry_id = timekeeping_arrange.entry(company:, user: employee, project:)
    before = entry_write_counts

    answer = replay_only_delete_request(entry_id, timekeeping_arrange.token_for(admin), key: SecureRandom.uuid,
                                                                                       replay_only: false)

    expect([answer.status, answer.parsed_body]).to eq([409, { "reason" => "version_conflict" }])
    expect(Entry.find(entry_id).discarded_at).to be_nil
    expect(entry_write_counts).to eq(before)
  end

  it "replays a committed delete after the generation advanced, writing nothing more" do
    entry_id = timekeeping_arrange.entry(company:, user: employee, project:)
    token = timekeeping_arrange.token_for(admin)
    key = SecureRandom.uuid
    first = replay_only_delete_request(entry_id, token, key:, replay_only: false, if_match: nil)
    first_body = first.parsed_body
    expect(first.status).to eq(200)
    discarded_at = Entry.find(entry_id).discarded_at
    after_first = entry_write_counts

    timekeeping_arrange.set_generation(timekeeping_arrange.current_generation + 1)
    replay = replay_only_delete_request(entry_id, token, key:)

    expect([replay.status, replay.parsed_body]).to eq([200, first_body])
    expect(Entry.find(entry_id).discarded_at).to eq(discarded_at)
    expect(entry_write_counts).to eq(after_first)
  end

  it "answers not_found to another actor's replay and to a replay of another entry under the same key" do
    deleted_id = timekeeping_arrange.entry(company:, user: employee, project:)
    other_id = timekeeping_arrange.entry(company:, user: employee, project:)
    key = SecureRandom.uuid
    replay_only_delete_request(deleted_id, timekeeping_arrange.token_for(admin), key:, replay_only: false, if_match: nil)
    after_first = entry_write_counts

    colleague_admin = timekeeping_arrange.user(company:, role: "admin")
    other_actor = replay_only_delete_request(deleted_id, timekeeping_arrange.token_for(colleague_admin), key:)
    expect([other_actor.status, other_actor.parsed_body]).to eq([404, { "reason" => "not_found" }])

    other_entry = replay_only_delete_request(other_id, timekeeping_arrange.token_for(admin), key:)
    expect([other_entry.status, other_entry.parsed_body]).to eq([404, { "reason" => "not_found" }])
    expect(Entry.find(other_id).discarded_at).to be_nil
    expect(entry_write_counts).to eq(after_first)
  end
end
