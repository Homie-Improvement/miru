require "rails_helper"
require_relative "../../../../../support/timekeeping/fake_timekeeping"

RSpec.describe "Api::V1::TimesheetEntry::BulkActionController forwarded tenant boundary", type: :request do
  let(:company) { create(:company) }
  let(:client) { create(:client, company:) }
  let(:project) { create(:project, client:, billable: true) }
  let(:target_project) { create(:project, client:, billable: true) }
  let(:admin) { create(:user, current_workspace_id: company.id) }
  let(:other_company) { create(:company) }
  let(:other_user) { create(:user, current_workspace_id: other_company.id) }
  let(:other_project) { create(:project, client: create(:client, company: other_company), billable: true) }
  let(:base_url) { "http://timekeeping.test" }
  let(:fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  around do |example|
    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV, base_url) do
      with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV, timekeeping_key_pair.to_pem) { example.run }
    end
  end

  before do
    create(:employment, company:, user: admin)
    admin.add_role :admin, company
    fake.register_company(id: company.id, edit_days: company.timesheet_edit_days)
    fake.register_user(id: admin.id, company_id: company.id, role: "admin")
    fake.register_project(id: project.id, company_id: company.id)
    fake.register_project(id: target_project.id, company_id: company.id)
    fake.register_project(id: other_project.id, company_id: other_company.id)
    route_timekeeping_to_fake(fake, base_url:)
    TimekeepingOwnership.current.update!(owner: "timekeeping", generation: 2, handoff_step: nil)
    fake.generation = 2
    sign_in admin
  end

  it "forwarded bulk move of only another company's entry answers 422 and sends no bulk move to Timekeeping" do
    foreign = fake.add_entry(company_id: other_company.id, user_id: other_user.id, project_id: other_project.id,
                             work_date: Date.current.iso8601)

    send_request :patch, api_v1_bulk_action_path,
      params: { ids: [foreign["id"]], project_id: target_project.id }, headers: auth_headers(admin)

    # An id from another company is dropped exactly like a missing id: 422 with today's message, never 404.
    expect(response).to have_http_status(:unprocessable_content)
    expect(json_response["error"]).to eq("Failed to update timesheet entries")
    expect(fake.requests.none? { |request| request[:path].to_s.end_with?("/entries/bulk-move") }).to be(true)
    expect(fake.stored_entry(foreign["id"])["project_id"]).to eq(other_project.id)
  end
end
