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
    Rails.logger = logger
    ActionController::Base.logger = logger
    yield
    io.string
  ensure
    Rails.logger = previous_rails_logger
    ActionController::Base.logger = previous_controller_logger
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
      logs = capture_logs { Rails.logger.info("token=#{marker}") }

      expect(logs).to include(marker)
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
end
