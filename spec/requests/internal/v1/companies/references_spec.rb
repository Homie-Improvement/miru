# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Internal::V1::Companies::References", type: :request do
  let(:contract) { TimekeepingContract.load(:reference) }
  let(:company_a) { create(:company, timesheet_edit_days: 7) }
  let(:company_b) { create(:company, timesheet_edit_days: 30) }
  let(:project_a) { create(:project, client: create(:client, company: company_a), billable: true) }
  let(:project_b) { create(:project, client: create(:client, company: company_b), billable: false) }
  let(:shared_user) { create(:user) }
  let(:b_only_user) { create(:user) }

  before do
    create(:employment, company: company_a, user: shared_user)
    create(:employment, company: company_b, user: shared_user)
    create(:employment, company: company_b, user: b_only_user)
    shared_user.add_role(:admin, company_a)
    shared_user.add_role(:manager, company_b)
    b_only_user.add_role(:owner, company_b)
    create(:project_member, project: project_a, user: shared_user)
    create(:project_member, project: project_b, user: b_only_user)
  end

  def get_reference(company_id, token:, project_ids: [project_a.id, project_b.id])
    headers = token.nil? ? {} : { "Authorization" => "Bearer #{token}" }
    get "/internal/v1/companies/#{company_id}/reference", params: { project_ids: project_ids.join(",") }, headers:
  end

  def expect_refused_without_data
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to eq("reason" => "unauthorized")
    [project_a.id, project_b.id, shared_user.id, b_only_user.id].each do |id|
      expect(response.body).not_to include(id.to_s)
    end
    expect(response.body).not_to include("admin", "billable")
  end

  # The test environment logs at ERROR; production logs requests at INFO.
  # Capture at DEBUG so a token logged at any level is seen.
  def capture_logs
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    logger.level = Logger::DEBUG
    previous_rails_logger = Rails.logger
    previous_controller_logger = ActionController::Base.logger
    previous_api_logger = ActionController::API.logger
    Rails.logger = logger
    ActionController::Base.logger = logger
    ActionController::API.logger = logger
    yield
    io.string
  ensure
    Rails.logger = previous_rails_logger
    ActionController::Base.logger = previous_controller_logger
    ActionController::API.logger = previous_api_logger
  end

  describe "refusals" do
    it "refuses every request when TIMEKEEPING_SERVICE_TOKEN is unset or blank" do
      [nil, ""].each do |configured|
        with_timekeeping_env("TIMEKEEPING_SERVICE_TOKEN", configured) do
          get_reference(company_a.id, token: "")
          expect_refused_without_data
          get_reference(company_a.id, token: nil)
          expect_refused_without_data
        end
      end
    end

    it "refuses a request with no Authorization header" do
      with_timekeeping_service_token do
        get_reference(company_a.id, token: nil)
        expect_refused_without_data
      end
    end

    it "refuses a wrong service token" do
      with_timekeeping_service_token do
        get_reference(company_a.id, token: SecureRandom.hex(32))
        expect_refused_without_data
      end
    end

    it "refuses a valid user token" do
      user_token = Timekeeping::UserToken.mint(user: shared_user, company: company_a, private_key: timekeeping_key_pair)

      with_timekeeping_service_token do
        get_reference(company_a.id, token: user_token)
        expect_refused_without_data
      end
    end

    it "refuses an unauthenticated request for a company that does not exist the same way" do
      with_timekeeping_service_token do
        get_reference(Company.maximum(:id).to_i + 1000, token: nil)
        expect_refused_without_data
      end
    end
  end

  describe "logging" do
    it "catches a token written at INFO, proving the capture sees request-level logs" do
      marker = SecureRandom.hex(16)
      controller_marker = SecureRandom.hex(16)
      logs = capture_logs do
        Rails.logger.info("token=#{marker}")
        Internal::V1::Companies::ReferencesController.logger.info("token=#{controller_marker}")
      end

      expect(logs).to include(marker, controller_marker)
    end

    it "writes neither the service token nor a user token into the log or the body" do
      user_token = Timekeeping::UserToken.mint(user: shared_user, company: company_a, private_key: timekeeping_key_pair)

      with_timekeeping_service_token do |service_token|
        bodies = []
        logs = capture_logs do
          get_reference(company_a.id, token: user_token)
          bodies << response.body
          get_reference(company_a.id, token: "#{service_token}x")
          bodies << response.body
          get_reference(company_a.id, token: service_token)
          bodies << response.body
        end

        [logs, *bodies].each do |text|
          expect(text).not_to include(service_token)
          expect(text).not_to include(user_token)
        end
      end
    end
  end

  describe "facts" do
    it "returns only the named company's facts in the contract's shape" do
      with_timekeeping_service_token do |token|
        get_reference(company_a.id, token:)
      end

      body = response.parsed_body
      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(body.keys).to match_array(contract["response_fields"])
      body["users"].each { |user| expect(user.keys).to match_array(contract["user_fields"]) }
      body["projects"].each { |project| expect(project.keys).to match_array(contract["project_fields"]) }

      expect(body["company_id"]).to eq(company_a.id)
      expect(body["edit_days"]).to eq(7)
      expect(body["users"]).to eq([{ "id" => shared_user.id, "role" => "admin" }])
      expect(body["projects"]).to eq(
        [{ "id" => project_a.id, "company_id" => company_a.id, "billable" => true, "member_user_ids" => [shared_user.id] }]
      )
    end

    it "reports another company's project as missing, like an id that does not exist" do
      nonexistent_id = Project.maximum(:id).to_i + 1000

      bodies = with_timekeeping_service_token do |token|
        [project_b.id, nonexistent_id].map do |id|
          get_reference(company_a.id, token:, project_ids: [id])
          expect(response).to have_http_status(:ok)
          response.parsed_body
        end
      end

      foreign, nonexistent = bodies
      expect(foreign["missing_project_ids"]).to eq([project_b.id])
      expect(nonexistent["missing_project_ids"]).to eq([nonexistent_id])
      expect(foreign.except("missing_project_ids")).to eq(nonexistent.except("missing_project_ids"))
      expect(foreign["projects"]).to eq([])
      expect(foreign["company_id"]).to eq(company_a.id)
      expect(foreign["users"].pluck("id")).not_to include(b_only_user.id)
    end

    it "returns a mixed list with the other company's project only in missing_project_ids" do
      with_timekeeping_service_token do |token|
        get_reference(company_a.id, token:)
      end

      body = response.parsed_body
      expect(body["projects"].pluck("id")).to eq([project_a.id])
      expect(body["missing_project_ids"]).to eq([project_b.id])
      expect(body["projects"].pluck("billable")).to eq([true])
    end

    it "accepts project_ids as an array" do
      with_timekeeping_service_token do |token|
        get "/internal/v1/companies/#{company_a.id}/reference",
          params: { project_ids: [project_a.id] }, headers: { "Authorization" => "Bearer #{token}" }
      end

      expect(response.parsed_body["projects"].pluck("id")).to eq([project_a.id])
    end

    it "answers not_found for an unknown or malformed company id" do
      with_timekeeping_service_token do |token|
        [Company.maximum(:id).to_i + 1000, "abc"].each do |company_id|
          get_reference(company_id, token:)
          expect(response).to have_http_status(:not_found)
          expect(response.parsed_body).to eq("reason" => "not_found")
        end
      end
    end

    it "answers invalid_project_ids for malformed or too many ids without echoing them" do
      with_timekeeping_service_token do |token|
        get_reference(company_a.id, token:, project_ids: [project_a.id, "zz-hostile"])
        expect(response).to have_http_status(422)
        expect(response.parsed_body).to eq("reason" => "invalid_project_ids")
        expect(response.body).not_to include("zz-hostile")

        get_reference(company_a.id, token:, project_ids: (1..(contract["max_project_ids"] + 1)).to_a)
        expect(response).to have_http_status(422)
        expect(response.parsed_body).to eq("reason" => "invalid_project_ids")
      end
    end
  end

  describe "owned agent ids" do
    it "answers invalid_agent_ids for malformed or too many agent ids without echoing them" do
      with_timekeeping_service_token do |token|
        headers = { "Authorization" => "Bearer #{token}" }
        get "/internal/v1/companies/#{company_a.id}/reference",
            params: { project_ids: "", agent_ids: "7,zz-hostile-agent" }, headers: headers
        expect(response).to have_http_status(422)
        expect(response.parsed_body).to eq("reason" => "invalid_agent_ids")
        expect(response.body).not_to include("zz-hostile-agent")

        get "/internal/v1/companies/#{company_a.id}/reference",
            params: { project_ids: "", agent_ids: (1..(contract["max_agent_ids"] + 1)).to_a.join(",") }, headers: headers
        expect(response).to have_http_status(422)
        expect(response.parsed_body).to eq("reason" => "invalid_agent_ids")
      end
    end

    # "Timekeeping cannot yet tell another company's agent from one of the company's own agents that has no entries."
    # The ownership fact answers for the path's company only, so another company's agent id reads exactly like
    # an id no agent has, and the fact cannot be used to probe other companies.
    it "lists only the path company's requested agents in owned_agent_ids and answers another company's agent like an unknown id" do
      own_agent = create(:agent, company: company_a, user: shared_user)
      foreign_agent = create(:agent, company: company_b, user: b_only_user)
      unknown_agent_id = Agent.maximum(:id).to_i + 1000
      requests = [
        [own_agent.id, foreign_agent.id, unknown_agent_id], [own_agent.id, foreign_agent.id],
        [own_agent.id, unknown_agent_id], [foreign_agent.id], [unknown_agent_id], []
      ]

      bodies = with_timekeeping_service_token do |token|
        requests.map do |agent_ids|
          get "/internal/v1/companies/#{company_a.id}/reference",
              params: { project_ids: "", agent_ids: agent_ids.join(",") },
              headers: { "Authorization" => "Bearer #{token}" }
          expect(response).to have_http_status(:ok)
          response.parsed_body
        end
      end

      all_kinds, own_and_foreign, own_and_unknown, foreign, unknown, none_requested = bodies
      expect(contract["response_fields"]).to include("owned_agent_ids")
      expect(all_kinds["owned_agent_ids"]).to eq([own_agent.id])
      expect(own_and_foreign["owned_agent_ids"]).to eq([own_agent.id])
      expect(own_and_foreign).to eq(own_and_unknown)
      expect(foreign["owned_agent_ids"]).to eq([])
      expect(foreign).to eq(unknown)
      expect(none_requested["owned_agent_ids"]).to eq([])
      expect(foreign["agents"].pluck("id")).not_to include(foreign_agent.id)
    end
  end

  context "more tests 2", type: :request do
  # "The monolith serves invoice facts `{id, company_id}` on the reference endpoint, the pattern of `docs/architecture/timekeeping-soa.md` line 378."
  # The facts answer for the path company only, so another company's invoice (or its pending intent) reads exactly
  # like an id no invoice has, and the endpoint cannot be used to probe other companies' invoices.
  it "lists only the path company's requested invoices and answers another company's invoice or intent like an unknown id" do
    own_invoice = create(:invoice, company: company_a, client: create(:client, company: company_a))
    foreign_invoice = create(:invoice, company: company_b, client: create(:client, company: company_b))
    foreign_intent_id = Invoice.maximum(:id).to_i + 500
    InvoiceOperationIntent.create!(company_id: company_b.id, invoice_id: foreign_intent_id,
                                   operation_id: SecureRandom.uuid, state: "pending", generation: 1,
                                   disposition: "active", desired_entry_ids: [], created_at: Time.current)
    unknown_id = Invoice.maximum(:id).to_i + 1000
    requests = [[own_invoice.id, foreign_invoice.id, unknown_id], [foreign_invoice.id], [unknown_id], [foreign_intent_id]]

    bodies = with_timekeeping_service_token do |token|
      requests.map do |invoice_ids|
        get "/internal/v1/companies/#{company_a.id}/reference",
            params: { project_ids: "", invoice_ids: invoice_ids.join(",") },
            headers: { "Authorization" => "Bearer #{token}" }
        expect(response).to have_http_status(:ok)
        response.parsed_body
      end
    end

    mixed, foreign, unknown, foreign_intent = bodies
    expect(contract["response_fields"]).to include("invoices")
    expect(mixed.keys).to match_array(contract["response_fields"])
    expect(mixed["invoices"]).to eq([{ "id" => own_invoice.id, "company_id" => company_a.id }])
    expect(foreign["invoices"]).to eq([])
    expect(foreign).to eq(unknown)
    expect(foreign_intent["invoices"]).to eq([])
  end
  end

  context "more tests 3", type: :request do
  # invoice_ids is caller input written into a database query, so a malformed or oversized list is refused
  # before any lookup, and the refusal does not repeat what was sent.
  it "answers invalid_invoice_ids for malformed or too many invoice ids without echoing them" do
    with_timekeeping_service_token do |token|
      headers = { "Authorization" => "Bearer #{token}" }
      get "/internal/v1/companies/#{company_a.id}/reference",
          params: { project_ids: "", invoice_ids: "7,zz-hostile-invoice" }, headers: headers
      expect(response).to have_http_status(422)
      expect(response.parsed_body).to eq("reason" => "invalid_invoice_ids")
      expect(response.body).not_to include("zz-hostile-invoice")

      get "/internal/v1/companies/#{company_a.id}/reference",
          params: { project_ids: "", invoice_ids: "-5" }, headers: headers
      expect(response).to have_http_status(422)
      expect(response.parsed_body).to eq("reason" => "invalid_invoice_ids")

      get "/internal/v1/companies/#{company_a.id}/reference",
          params: { project_ids: "", invoice_ids: (1..(contract["max_invoice_ids"] + 1)).to_a.join(",") },
          headers: headers
      expect(response).to have_http_status(422)
      expect(response.parsed_body).to eq("reason" => "invalid_invoice_ids")
    end
  end
  end

  context "more tests 4", type: :request do
  # "The monolith serves invoice facts `{id, company_id}` on the reference endpoint"
  # The facts answer for the path company only, so another company's invoice, or another company's in-flight
  # intent for an id, reads exactly like an id no invoice has.
  it "R4 lists only the path company's own invoices and pending intents as invoice facts and answers another company's invoice like an unknown id" do
    own_invoice = create(:invoice, company: company_a, client: create(:client, company: company_a))
    foreign_invoice = create(:invoice, company: company_b, client: create(:client, company: company_b))
    unknown_id = Invoice.maximum(:id).to_i + 1000
    intent_only_id = unknown_id + 1
    foreign_intent_id = unknown_id + 2
    InvoiceOperationIntent.create!(company_id: company_a.id, invoice_id: intent_only_id, operation_id: SecureRandom.uuid,
                                   state: "pending", generation: 1, disposition: "active", desired_entry_ids: [],
                                   created_at: Time.current)
    InvoiceOperationIntent.create!(company_id: company_b.id, invoice_id: foreign_intent_id, operation_id: SecureRandom.uuid,
                                   state: "pending", generation: 1, disposition: "active", desired_entry_ids: [],
                                   created_at: Time.current)
    requests = [
      [own_invoice.id, foreign_invoice.id, intent_only_id, foreign_intent_id],
      [foreign_invoice.id], [unknown_id], [foreign_intent_id]
    ]

    bodies = with_timekeeping_service_token do |token|
      requests.map do |invoice_ids|
        get "/internal/v1/companies/#{company_a.id}/reference",
            params: { project_ids: "", invoice_ids: invoice_ids.join(",") },
            headers: { "Authorization" => "Bearer #{token}" }
        expect(response).to have_http_status(:ok)
        response.parsed_body
      end
    end

    mixed, foreign, unknown, foreign_intent = bodies
    expect(mixed["invoices"]).to match_array([
      { "id" => own_invoice.id, "company_id" => company_a.id },
      { "id" => intent_only_id, "company_id" => company_a.id }
    ])
    expect(mixed["invoices"].pluck("company_id").uniq).to eq([company_a.id])
    expect(foreign["invoices"]).to eq([])
    expect(foreign).to eq(unknown)
    expect(foreign_intent).to eq(unknown)
  end
  end

  context "more tests 5", type: :request do
  # "The monolith serves invoice facts `{id, company_id}` on the reference endpoint"
  it "lists the path company's own, discarded and pending-intent invoices as {id, company_id} and leaves another company's invoice out like an unknown id" do
    own_invoice = create(:invoice, company: company_a, client: create(:client, company: company_a))
    discarded_invoice = create(:invoice, company: company_a, client: create(:client, company: company_a))
    discarded_invoice.discard
    foreign_invoice = create(:invoice, company: company_b, client: create(:client, company: company_b))
    unknown_id = Invoice.maximum(:id).to_i + 1000
    intent_only_id = unknown_id + 1
    InvoiceOperationIntent.create!(company_id: company_a.id, invoice_id: intent_only_id, operation_id: SecureRandom.uuid,
                                   state: "pending", generation: 1, disposition: "active", desired_entry_ids: [],
                                   created_at: Time.current)
    foreign_intent_id = unknown_id + 2
    InvoiceOperationIntent.create!(company_id: company_b.id, invoice_id: foreign_intent_id, operation_id: SecureRandom.uuid,
                                   state: "pending", generation: 1, disposition: "active", desired_entry_ids: [],
                                   created_at: Time.current)

    requested = [own_invoice.id, discarded_invoice.id, foreign_invoice.id, unknown_id, intent_only_id, foreign_intent_id]
    bodies = with_timekeeping_service_token do |token|
      [requested, [foreign_invoice.id], [unknown_id], []].map do |invoice_ids|
        get "/internal/v1/companies/#{company_a.id}/reference",
            params: { project_ids: "", invoice_ids: invoice_ids.join(",") },
            headers: { "Authorization" => "Bearer #{token}" }
        expect(response).to have_http_status(:ok)
        response.parsed_body
      end
    end
    all_kinds, foreign, unknown, none_requested = bodies

    expect(contract["response_fields"]).to include("invoices")
    expect(contract["invoice_fields"]).to eq(%w[id company_id])
    expect(all_kinds.keys).to match_array(contract["response_fields"])
    expect(all_kinds["invoices"]).to match_array([
      { "id" => own_invoice.id, "company_id" => company_a.id },
      { "id" => discarded_invoice.id, "company_id" => company_a.id },
      { "id" => intent_only_id, "company_id" => company_a.id }
    ])
    expect(all_kinds["invoices"].pluck("id").count(own_invoice.id)).to eq(1)
    expect(foreign["invoices"]).to eq([])
    expect(foreign).to eq(unknown)
    expect(none_requested["invoices"]).to eq([])
  end
  end

  context "more tests 6", type: :request do
  # The invoice id list is caller input on an internal endpoint, so it is bounded and checked like agent_ids.
  it "refuses malformed or too many invoice_ids with 422 invalid_invoice_ids" do
    limit = contract["max_invoice_ids"]
    expect(limit).to eq(200)

    with_timekeeping_service_token do |token|
      headers = { "Authorization" => "Bearer #{token}" }
      ["abc", "1,-2", "1,,2", (1..(limit + 1)).to_a.join(",")].each do |invoice_ids|
        get "/internal/v1/companies/#{company_a.id}/reference", params: { project_ids: "", invoice_ids: }, headers: headers
        expect(response).to have_http_status(422)
        expect(response.parsed_body).to eq("reason" => "invalid_invoice_ids")
      end

      get "/internal/v1/companies/#{company_a.id}/reference",
          params: { project_ids: "", invoice_ids: (1..limit).to_a.join(",") }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["invoices"]).to eq([])
    end
  end
  end
end

# Generated by Descant: acceptance tests below.
RSpec.describe "Internal::V1::Companies::References agents", type: :request do
  # The issue asks the reference endpoint "to return the company's agents with their users". reference.yml's
  # company_scope rule says every fact belongs to the company in the path, so another company's agent, or an
  # agent's name or metadata, must never cross to Timekeeping.
  # Covers a request with an empty project_ids and one without the parameter.
  it "returns only the path company's agents, active or not, each with only an id and its user's id" do
    contract = TimekeepingContract.load(:reference)
    company_a = create(:company)
    company_b = create(:company)
    user_a = create(:user)
    create(:employment, company: company_a, user: user_a)
    own_agent = create(:agent, company: company_a, user: user_a, name: "Visible Agent Name",
                               metadata: { "secret" => "agent-meta" })
    inactive_agent = create(:agent, company: company_a, name: "Paused Agent", active: false)
    foreign_agent = create(:agent, company: company_b, name: "Foreign Agent Name")

    [{ project_ids: "" }, {}].each do |params|
      with_timekeeping_service_token do |token|
        get "/internal/v1/companies/#{company_a.id}/reference", params:,
                                                                headers: { "Authorization" => "Bearer #{token}" }
      end

      body = response.parsed_body
      expect(response).to have_http_status(:ok)
      expect(contract["response_fields"]).to include("agents")
      expect(contract["agent_fields"]).to eq(%w[id user_id])
      expect(body.keys).to match_array(contract["response_fields"])
      body["agents"].each { |agent| expect(agent.keys).to match_array(contract["agent_fields"]) }
      expect(body["agents"]).to match_array([
        { "id" => own_agent.id, "user_id" => user_a.id },
        { "id" => inactive_agent.id, "user_id" => inactive_agent.user_id }
      ])
      expect(body["agents"].pluck("id")).not_to include(foreign_agent.id)
      expect(response.body).not_to include("Visible Agent Name", "Foreign Agent Name", "agent-meta")
    end
  end
end
