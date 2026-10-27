require "rails_helper"
require_relative "../../../../../support/timekeeping/fake_timekeeping"

RSpec.describe "Api::V1::TimesheetEntry::BulkActionController forwarded foreign-only bulk move", type: :request do
  let(:company) { create(:company) }
  let(:other_company) { create(:company) }
  let(:target_project) { create(:project, billable: true, client: create(:client, company:)) }
  let(:other_project) { create(:project, billable: true, client: create(:client, company: other_company)) }
  let(:admin) { create(:user, current_workspace_id: company.id) }
  let(:outsider) { create(:user, current_workspace_id: other_company.id) }
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
    create(:employment, company: other_company, user: outsider)
    fake.register_company(id: company.id, edit_days: company.timesheet_edit_days)
    fake.register_user(id: admin.id, company_id: company.id, role: "admin")
    fake.register_project(id: target_project.id, company_id: company.id)
    route_timekeeping_to_fake(fake, base_url:)
    TimekeepingOwnership.current.update!(owner: "timekeeping", generation: 2, handoff_step: nil)
    fake.generation = 2
    sign_in admin
  end

  it "forwarded bulk move of only another company's entry answers 422 and sends no bulk move" do
    foreign_entry_id = fake.add_entry(company_id: other_company.id, user_id: outsider.id, project_id: other_project.id,
                                      work_date: Date.current.iso8601, note: "Theirs").fetch("id")

    send_request :patch, api_v1_bulk_action_path,
      params: { ids: [foreign_entry_id], project_id: target_project.id }, headers: auth_headers(admin)

    # A foreign id is dropped exactly like a missing one, so the answer never shows that it exists elsewhere.
    expect(response).to have_http_status(:unprocessable_content)
    expect(json_response["error"]).to eq("Failed to update timesheet entries")
    expect(fake.requests.select { |request| request[:path].to_s.include?("bulk-move") }).to be_empty
    expect(fake.stored_entry(foreign_entry_id)["project_id"]).to eq(other_project.id)
  end
end

require "rails_helper"
require_relative "../../../../../support/timekeeping/fake_timekeeping"

RSpec.describe "Api::V1::TimesheetEntry::BulkActionController forwarded mixed-tenant bulk move", type: :request do
  let(:company) { create(:company) }
  let(:other_company) { create(:company) }
  let(:project) { create(:project, billable: true, client: create(:client, company:)) }
  let(:target_project) { create(:project, billable: true, client: create(:client, company:)) }
  let(:other_project) { create(:project, billable: true, client: create(:client, company: other_company)) }
  let(:admin) { create(:user, current_workspace_id: company.id) }
  let(:outsider) { create(:user, current_workspace_id: other_company.id) }
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
    create(:employment, company: other_company, user: outsider)
    fake.register_company(id: company.id, edit_days: company.timesheet_edit_days)
    fake.register_user(id: admin.id, company_id: company.id, role: "admin")
    fake.register_project(id: project.id, company_id: company.id)
    fake.register_project(id: target_project.id, company_id: company.id)
    route_timekeeping_to_fake(fake, base_url:)
    TimekeepingOwnership.current.update!(owner: "timekeeping", generation: 2, handoff_step: nil)
    fake.generation = 2
    sign_in admin
  end

  it "forwarded bulk move with own and foreign ids forwards only the own id and never renders the foreign entry" do
    own_entry_id = fake.add_entry(company_id: company.id, user_id: admin.id, project_id: project.id,
                                  work_date: Date.current.iso8601, note: "Mine").fetch("id")
    foreign_entry_id = fake.add_entry(company_id: other_company.id, user_id: outsider.id, project_id: other_project.id,
                                      work_date: Date.current.iso8601, note: "Foreign private note").fetch("id")

    send_request :patch, api_v1_bulk_action_path,
      params: { ids: [own_entry_id, foreign_entry_id], project_id: target_project.id }, headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    bulk_moves = fake.requests.select { |request| request[:path].to_s.include?("bulk-move") }
    expect(bulk_moves.size).to eq(1)
    # Only ids the company-scoped lookup resolved are ever sent; raw request ids never reach Timekeeping.
    expect(bulk_moves.first[:body]["entry_ids"].map(&:to_i)).to eq([own_entry_id])
    expect(bulk_moves.first[:path]).to include("/v1/companies/#{company.id}/")
    expect(fake.stored_entry(own_entry_id)["project_id"]).to eq(target_project.id)
    expect(fake.stored_entry(foreign_entry_id)["project_id"]).to eq(other_project.id)
    expect(response.body).not_to include("Foreign private note")
  end
end

require "rails_helper"
require_relative "../../../../../support/timekeeping/fake_timekeeping"

RSpec.describe "Api::V1::TimesheetEntry::BulkActionController forwarded employee bulk move scope", type: :request do
  let(:company) { create(:company) }
  let(:project) { create(:project, billable: true, client: create(:client, company:)) }
  let(:target_project) { create(:project, billable: true, client: create(:client, company:)) }
  let(:employee) { create(:user, current_workspace_id: company.id) }
  let(:colleague) { create(:user, current_workspace_id: company.id) }
  let(:base_url) { "http://timekeeping.test" }
  let(:fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  around do |example|
    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV, base_url) do
      with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV, timekeeping_key_pair.to_pem) { example.run }
    end
  end

  before do
    [employee, colleague].each do |member|
      create(:employment, company:, user: member)
      member.add_role :employee, company
      create(:project_member, project:, user: member)
      create(:project_member, project: target_project, user: member)
      fake.register_user(id: member.id, company_id: company.id, role: "employee")
    end
    fake.register_company(id: company.id, edit_days: company.timesheet_edit_days)
    fake.register_project(id: project.id, company_id: company.id)
    fake.register_project(id: target_project.id, company_id: company.id)
    route_timekeeping_to_fake(fake, base_url:)
    TimekeepingOwnership.current.update!(owner: "timekeeping", generation: 2, handoff_step: nil)
    fake.generation = 2
    sign_in employee
  end

  it "forwarded bulk move by an employee never forwards or moves a colleague's entry" do
    own_entry_id = fake.add_entry(company_id: company.id, user_id: employee.id, project_id: project.id,
                                  work_date: Date.current.iso8601).fetch("id")
    colleague_entry_id = fake.add_entry(company_id: company.id, user_id: colleague.id, project_id: project.id,
                                        work_date: Date.current.iso8601).fetch("id")

    send_request :patch, api_v1_bulk_action_path,
      params: { ids: [own_entry_id, colleague_entry_id], project_id: target_project.id }, headers: auth_headers(employee)

    # An employee's ids resolve only to their own entries, so a colleague's id is dropped before any write.
    expect(response).to have_http_status(:ok)
    sent_ids = fake.requests.select { |request| request[:path].to_s.include?("bulk-move") }
      .flat_map { |request| request[:body]["entry_ids"].map(&:to_i) }
    expect(sent_ids).not_to include(colleague_entry_id)
    expect(fake.stored_entry(colleague_entry_id)["project_id"]).to eq(project.id)
    expect(fake.stored_entry(own_entry_id)["project_id"]).to eq(target_project.id)
  end
end

require "rails_helper"
require_relative "../../../../../support/timekeeping/fake_timekeeping"

RSpec.describe "Api::V1::TimesheetEntry::BulkActionController forwarded foreign target project", type: :request do
  let(:company) { create(:company) }
  let(:other_company) { create(:company) }
  let(:project) { create(:project, billable: true, client: create(:client, company:)) }
  let(:foreign_project) { create(:project, billable: true, client: create(:client, company: other_company)) }
  let(:admin) { create(:user, current_workspace_id: company.id) }
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
    route_timekeeping_to_fake(fake, base_url:)
    TimekeepingOwnership.current.update!(owner: "timekeeping", generation: 2, handoff_step: nil)
    fake.generation = 2
    sign_in admin
  end

  it "forwarded bulk move to another company's project answers 404 and forwards nothing" do
    entry_id = fake.add_entry(company_id: company.id, user_id: admin.id, project_id: project.id,
                              work_date: Date.current.iso8601).fetch("id")

    send_request :patch, api_v1_bulk_action_path,
      params: { ids: [entry_id], project_id: foreign_project.id }, headers: auth_headers(admin)

    # The project check runs before any write, so no write token ever names a project the caller cannot see.
    expect(response).to have_http_status(:not_found)
    expect(fake.requests.select { |request| request[:path].to_s.include?("bulk-move") }).to be_empty
    expect(fake.stored_entry(entry_id)["project_id"]).to eq(project.id)
  end
end

require "rails_helper"
require_relative "../../../../../support/timekeeping/fake_timekeeping"

RSpec.describe "Api::V1::TimesheetEntry::BulkActionController forwarded bulk move credentials", type: :request do
  let(:company) { create(:company) }
  let(:project) { create(:project, billable: true, client: create(:client, company:)) }
  let(:target_project) { create(:project, billable: true, client: create(:client, company:)) }
  let(:admin) { create(:user, current_workspace_id: company.id) }
  let(:colleague) { create(:user, current_workspace_id: company.id) }
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
    create(:employment, company:, user: colleague)
    colleague.add_role :employee, company
    fake.register_company(id: company.id, edit_days: company.timesheet_edit_days)
    fake.register_user(id: admin.id, company_id: company.id, role: "admin")
    fake.register_user(id: colleague.id, company_id: company.id, role: "employee")
    fake.register_project(id: project.id, company_id: company.id)
    fake.register_project(id: target_project.id, company_id: company.id)
    route_timekeeping_to_fake(fake, base_url:)
    TimekeepingOwnership.current.update!(owner: "timekeeping", generation: 2, handoff_step: nil)
    fake.generation = 2
    sign_in admin
  end

  it "forwarded bulk move token names the signed-in actor and company and the request carries the monolith request id" do
    colleague_entry_id = fake.add_entry(company_id: company.id, user_id: colleague.id, project_id: project.id,
                                        work_date: Date.current.iso8601).fetch("id")

    send_request :patch, api_v1_bulk_action_path,
      params: { ids: [colleague_entry_id], project_id: target_project.id },
      headers: auth_headers(admin).merge("X-Request-Id" => "bulk-move-security-request")

    expect(response).to have_http_status(:ok)
    bulk_move = fake.requests.find { |request| request[:path].to_s.include?("bulk-move") }
    claims = Timekeeping::UserToken.verify(bulk_move[:headers]["Authorization"].delete_prefix("Bearer "),
                                           public_key: timekeeping_key_pair.public_key)

    # "Like the single-entry methods, each sends `Authorization` with a write `UserToken` for the context's actor and company, `Ownership-Generation`, an `Idempotency-Key` and `X-Request-Id`."
    expect(claims.user_id).to eq(admin.id)
    expect(claims.user_id).not_to eq(colleague.id)
    expect(claims.company_id).to eq(company.id)
    expect(claims.purpose).to eq("write")
    expect(bulk_move[:headers]["Ownership-Generation"]).to eq("2")
    expect(bulk_move[:headers]["X-Request-Id"]).to eq("bulk-move-security-request")
    expect(bulk_move[:headers]["Idempotency-Key"]).to be_present
    expect(response.body).not_to include(bulk_move[:headers]["Authorization"].delete_prefix("Bearer "))
  end
end

require "rails_helper"
require_relative "../../../../../support/timekeeping/fake_timekeeping"

RSpec.describe "Api::V1::TimesheetEntry::BulkActionController forwarded malformed bulk ids", type: :request do
  let(:company) { create(:company) }
  let(:project) { create(:project, billable: true, client: create(:client, company:)) }
  let(:target_project) { create(:project, billable: true, client: create(:client, company:)) }
  let(:admin) { create(:user, current_workspace_id: company.id) }
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
    route_timekeeping_to_fake(fake, base_url:)
    TimekeepingOwnership.current.update!(owner: "timekeeping", generation: 2, handoff_step: nil)
    fake.generation = 2
    sign_in admin
  end

  it "forwarded bulk move with a malformed id skips it and moves the valid entry instead of failing" do
    entry_id = fake.add_entry(company_id: company.id, user_id: admin.id, project_id: project.id,
                              work_date: Date.current.iso8601).fetch("id")

    send_request :patch, api_v1_bulk_action_path,
      params: { ids: [entry_id.to_s, "not-an-id"], project_id: target_project.id }, headers: auth_headers(admin)

    # Hostile input in the id list is dropped like an unknown id; it never becomes a server error.
    expect(response).to have_http_status(:ok)
    sent_ids = fake.requests.select { |request| request[:path].to_s.include?("bulk-move") }
      .flat_map { |request| request[:body]["entry_ids"] }
    expect(sent_ids.map(&:to_s)).to eq([entry_id.to_s])
    expect(fake.stored_entry(entry_id)["project_id"]).to eq(target_project.id)
  end
end

require "rails_helper"
require_relative "../../../../../support/timekeeping/fake_timekeeping"

RSpec.describe "Api::V1::TimesheetEntry::BulkActionController forwarded foreign-only bulk delete", type: :request do
  let(:company) { create(:company) }
  let(:other_company) { create(:company) }
  let(:other_project) { create(:project, billable: true, client: create(:client, company: other_company)) }
  let(:admin) { create(:user, current_workspace_id: company.id) }
  let(:outsider) { create(:user, current_workspace_id: other_company.id) }
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
    create(:employment, company: other_company, user: outsider)
    fake.register_company(id: company.id, edit_days: company.timesheet_edit_days)
    fake.register_user(id: admin.id, company_id: company.id, role: "admin")
    route_timekeeping_to_fake(fake, base_url:)
    TimekeepingOwnership.current.update!(owner: "timekeeping", generation: 2, handoff_step: nil)
    fake.generation = 2
    sign_in admin
  end

  it "forwarded bulk delete of only another company's entry answers 422 and discards nothing" do
    foreign_entry_id = fake.add_entry(company_id: other_company.id, user_id: outsider.id, project_id: other_project.id,
                                      work_date: Date.current.iso8601).fetch("id")

    send_request :delete, api_v1_bulk_action_path,
      params: { source: { ids: [foreign_entry_id] } }, headers: auth_headers(admin)

    # A foreign id is dropped like a missing one: same 422, and no delete is ever sent for it.
    expect(response).to have_http_status(:unprocessable_content)
    expect(fake.requests.select { |request| request[:path].to_s.include?("bulk-delete") }).to be_empty
    expect(fake.stored_entry(foreign_entry_id)["discarded_at"]).to be_nil
  end
end

require "rails_helper"

RSpec.describe "Api::V1::TimesheetEntry::BulkAction legacy generation bump", type: :request, committed_data: true do
  let(:bump_company) { create(:company) }
  let(:bump_client) { create(:client, company: bump_company) }
  let(:bump_source_project) { create(:project, billable: true, client: bump_client) }
  let(:bump_target_project) { create(:project, billable: true, client: bump_client) }
  let(:bump_admin) { create(:user, current_workspace_id: bump_company.id) }

  before do
    create(:employment, company: bump_company, user: bump_admin)
    bump_admin.add_role :admin, bump_company
    sign_in bump_admin
  end

  it "a legacy bulk move whose generation is bumped after the first entry update answers 409 and no entry stays moved" do
    entries = Array.new(2) do
      create(:timesheet_entry, user: bump_admin, project: bump_source_project, work_date: Date.current,
                               bill_status: "unbilled")
    end
    bumped = false
    allow_any_instance_of(TimesheetEntry).to receive(:update).and_wrap_original do |original, *args, **kwargs|
      result = original.call(*args, **kwargs)
      unless bumped
        bumped = true
        TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).increment!(:generation)
      end
      result
    end

    # "A generation bumped between two entry writes of one legacy bulk move gives 409, and no entry in that request moved."
    send_request :patch, api_v1_bulk_action_path,
      params: { ids: entries.map(&:id), project_id: bump_target_project.id },
      headers: auth_headers(bump_admin)

    expect(response).to have_http_status(:conflict)
    expect(json_response["reason"]).to eq("stale_generation")
    expect(TimesheetEntry.where(id: entries.map(&:id)).pluck(:project_id)).to all(eq(bump_source_project.id))
  end
end

require "rails_helper"
require_relative "../../../../../support/timekeeping/fake_timekeeping"

RSpec.describe "Api::V1::TimesheetEntry::BulkAction forwarded stale move", type: :request do
  let(:stale_company) { create(:company) }
  let(:stale_client) { create(:client, company: stale_company) }
  let(:stale_source_project) { create(:project, billable: true, client: stale_client) }
  let(:stale_target_project) { create(:project, billable: true, client: stale_client) }
  let(:stale_admin) { create(:user, current_workspace_id: stale_company.id) }
  let(:stale_base_url) { "http://timekeeping.test" }
  let(:stale_fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  around do |example|
    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV, stale_base_url) do
      with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV, timekeeping_key_pair.to_pem) { example.run }
    end
  end

  before do
    create(:employment, company: stale_company, user: stale_admin)
    stale_admin.add_role :admin, stale_company
    stale_fake.register_company(id: stale_company.id, edit_days: stale_company.timesheet_edit_days)
    stale_fake.register_user(id: stale_admin.id, company_id: stale_company.id, role: "admin")
    stale_fake.register_project(id: stale_source_project.id, company_id: stale_company.id)
    stale_fake.register_project(id: stale_target_project.id, company_id: stale_company.id)
    route_timekeeping_to_fake(stale_fake, base_url: stale_base_url)
    TimekeepingOwnership.current.update!(owner: "timekeeping", generation: 2, handoff_step: nil)
    sign_in stale_admin
  end

  it "a forwarded bulk move at a stale generation answers 409 and Timekeeping shows no entry moved" do
    stale_fake.generation = 2
    entries = Array.new(2) do
      stale_fake.add_entry(company_id: stale_company.id, user_id: stale_admin.id,
                           project_id: stale_source_project.id, work_date: Date.current.iso8601)
    end
    # Timekeeping has moved on to a later generation than the monolith expects.
    stale_fake.generation = 3

    # "A forwarded stale bulk move gives 409, and the fake shows no moves."
    send_request :patch, api_v1_bulk_action_path,
      params: { ids: entries.map { |entry| entry["id"] }, project_id: stale_target_project.id },
      headers: auth_headers(stale_admin)

    expect(response).to have_http_status(:conflict)
    entries.each do |entry|
      expect(stale_fake.stored_entry(entry["id"])["project_id"]).to eq(stale_source_project.id)
    end
  end
end

require "rails_helper"
require_relative "../../../../../support/timekeeping/fake_timekeeping"

RSpec.describe "Api::V1::TimesheetEntry::BulkAction handoff refusal", type: :request do
  let(:handoff_company) { create(:company) }
  let(:handoff_project) { create(:project, billable: true, client: create(:client, company: handoff_company)) }
  let(:handoff_admin) { create(:user, current_workspace_id: handoff_company.id) }
  let(:handoff_base_url) { "http://timekeeping.test" }
  let(:handoff_fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  around do |example|
    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV, handoff_base_url) do
      with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV, timekeeping_key_pair.to_pem) { example.run }
    end
  end

  before do
    create(:employment, company: handoff_company, user: handoff_admin)
    handoff_admin.add_role :admin, handoff_company
    handoff_fake.register_company(id: handoff_company.id, edit_days: handoff_company.timesheet_edit_days)
    handoff_fake.register_user(id: handoff_admin.id, company_id: handoff_company.id, role: "admin")
    handoff_fake.register_project(id: handoff_project.id, company_id: handoff_company.id)
    route_timekeeping_to_fake(handoff_fake, base_url: handoff_base_url)
    sign_in handoff_admin
  end

  it "a bulk delete during a handoff answers 503 ownership_moving and discards nothing locally or in Timekeeping" do
    # "When `handoff_step` is set, the gateway refuses entry writes, prepares and service commands with a retryable `503 ownership_moving`."
    legacy_entry = create(:timesheet_entry, user: handoff_admin, project: handoff_project, work_date: Date.current,
                                            bill_status: "unbilled")
    TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID).update_all(handoff_step: "close_admission")

    send_request :delete, api_v1_bulk_action_path, params: { source: { ids: [legacy_entry.id] } },
                                                   headers: auth_headers(handoff_admin)

    expect(response).to have_http_status(:service_unavailable)
    expect(json_response["reason"]).to eq("ownership_moving")
    expect(legacy_entry.reload.discarded_at).to be_nil

    handoff_fake.generation = 2
    forwarded_entry = handoff_fake.add_entry(company_id: handoff_company.id, user_id: handoff_admin.id,
                                             project_id: handoff_project.id, work_date: Date.current.iso8601)
    TimekeepingOwnership.current.update!(owner: "timekeeping", generation: 2, handoff_step: "close_admission")

    send_request :delete, api_v1_bulk_action_path, params: { source: { ids: [forwarded_entry["id"]] } },
                                                   headers: auth_headers(handoff_admin)

    expect(response).to have_http_status(:service_unavailable)
    expect(json_response["reason"]).to eq("ownership_moving")
    expect(handoff_fake.stored_entry(forwarded_entry["id"])["discarded_at"]).to be_nil
    expect(handoff_fake.requests.map { |request| request[:path] }).not_to include(a_string_ending_with("/bulk-delete"))
  end
end

require "rails_helper"
require_relative "../../../../../support/timekeeping/fake_timekeeping"

RSpec.describe "Api::V1::TimesheetEntry::BulkAction forwarded validation skip", type: :request do
  let(:skip_company) { create(:company) }
  let(:skip_client) { create(:client, company: skip_company) }
  let(:skip_source_project) { create(:project, billable: true, client: skip_client) }
  let(:skip_target_project) { create(:project, billable: false, client: skip_client) }
  let(:skip_admin) { create(:user, current_workspace_id: skip_company.id) }
  let(:skip_base_url) { "http://timekeeping.test" }
  let(:skip_fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  around do |example|
    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV, skip_base_url) do
      with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV, timekeeping_key_pair.to_pem) { example.run }
    end
  end

  before do
    create(:employment, company: skip_company, user: skip_admin)
    skip_admin.add_role :admin, skip_company
    skip_fake.register_company(id: skip_company.id, edit_days: skip_company.timesheet_edit_days)
    skip_fake.register_user(id: skip_admin.id, company_id: skip_company.id, role: "admin")
    skip_fake.register_project(id: skip_source_project.id, company_id: skip_company.id)
    skip_fake.register_project(id: skip_target_project.id, company_id: skip_company.id)
    route_timekeeping_to_fake(skip_fake, base_url: skip_base_url)
    TimekeepingOwnership.current.update!(owner: "timekeeping", generation: 2, handoff_step: nil)
    skip_fake.generation = 2
    sign_in skip_admin
  end

  it "a forwarded bulk move to a non-billable project answers 200 and leaves the unbilled entry on its project in Timekeeping" do
    entry = skip_fake.add_entry(company_id: skip_company.id, user_id: skip_admin.id,
                                project_id: skip_source_project.id, work_date: Date.current.iso8601,
                                bill_status: "unbilled")

    # "Failing entries are still skipped silently, as A9 does today."
    # The legacy save refuses an unbilled entry on a non-billable project, so the forwarded move skips it too.
    send_request :patch, api_v1_bulk_action_path,
      params: { ids: [entry["id"]], project_id: skip_target_project.id },
      headers: auth_headers(skip_admin)

    expect(response).to have_http_status(:ok)
    expect(json_response).not_to have_key("error")
    expect(skip_fake.stored_entry(entry["id"])["project_id"]).to eq(skip_source_project.id)
  end
end

require "rails_helper"
require_relative "../../../../../support/timekeeping/fake_timekeeping"

RSpec.describe "Api::V1::TimesheetEntry::BulkActionController forwarded mixed tenant ids", type: :request do
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

  it "forwarded bulk move of own and foreign ids forwards only the own id under the caller's company" do
    own = fake.add_entry(company_id: company.id, user_id: admin.id, project_id: project.id,
                         work_date: Date.current.iso8601)
    foreign = fake.add_entry(company_id: other_company.id, user_id: other_user.id, project_id: other_project.id,
                             work_date: Date.current.iso8601)

    send_request :patch, api_v1_bulk_action_path,
      params: { ids: [own["id"], foreign["id"]], project_id: target_project.id }, headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    bulk_requests = fake.requests.select { |request| request[:path].to_s.end_with?("/entries/bulk-move") }
    expect(bulk_requests.size).to eq(1)
    bulk_request = bulk_requests.first
    # Only ids the company-scoped lookup resolved are ever sent; the foreign id never reaches Timekeeping.
    expect(bulk_request[:body]["entry_ids"].map(&:to_i)).to eq([own["id"]])
    expect(bulk_request[:path]).to include("/v1/companies/#{company.id}/entries/bulk-move")
    claims = Timekeeping::UserToken.verify(bulk_request[:headers]["Authorization"].delete_prefix("Bearer "),
                                           public_key: timekeeping_key_pair.public_key)
    expect(claims.company_id).to eq(company.id)
    expect(claims.user_id).to eq(admin.id)
    expect(fake.stored_entry(own["id"])["project_id"]).to eq(target_project.id)
    expect(fake.stored_entry(foreign["id"])["project_id"]).to eq(other_project.id)
  end
end

require "rails_helper"
require_relative "../../../../../support/timekeeping/fake_timekeeping"

RSpec.describe "Api::V1::TimesheetEntry::BulkActionController forwarded employee scope", type: :request do
  let(:company) { create(:company) }
  let(:client) { create(:client, company:) }
  let(:project) { create(:project, client:, billable: true) }
  let(:target_project) { create(:project, client:, billable: true) }
  let(:employee) { create(:user, current_workspace_id: company.id) }
  let(:colleague) { create(:user, current_workspace_id: company.id) }
  let(:base_url) { "http://timekeeping.test" }
  let(:fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  around do |example|
    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV, base_url) do
      with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV, timekeeping_key_pair.to_pem) { example.run }
    end
  end

  before do
    create(:employment, company:, user: employee)
    employee.add_role :employee, company
    create(:employment, company:, user: colleague)
    colleague.add_role :employee, company
    [project, target_project].each do |member_project|
      create(:project_member, project: member_project, user: employee)
      create(:project_member, project: member_project, user: colleague)
    end
    fake.register_company(id: company.id, edit_days: company.timesheet_edit_days)
    fake.register_user(id: employee.id, company_id: company.id, role: "employee")
    fake.register_user(id: colleague.id, company_id: company.id, role: "employee")
    fake.register_project(id: project.id, company_id: company.id)
    fake.register_project(id: target_project.id, company_id: company.id)
    route_timekeeping_to_fake(fake, base_url:)
    TimekeepingOwnership.current.update!(owner: "timekeeping", generation: 2, handoff_step: nil)
    fake.generation = 2
    sign_in employee
  end

  it "forwarded employee bulk move never forwards or moves a colleague's entry" do
    own = fake.add_entry(company_id: company.id, user_id: employee.id, project_id: project.id,
                         work_date: Date.current.iso8601)
    colleagues = fake.add_entry(company_id: company.id, user_id: colleague.id, project_id: project.id,
                                work_date: Date.current.iso8601)

    send_request :patch, api_v1_bulk_action_path,
      params: { ids: [own["id"], colleagues["id"]], project_id: target_project.id }, headers: auth_headers(employee)

    # For employees, ids resolve only to their own entries; a colleague's id is dropped before any write.
    expect(response).to have_http_status(:ok)
    sent_ids = fake.requests
      .select { |request| request[:path].to_s.end_with?("/entries/bulk-move") }
      .flat_map { |request| request[:body]["entry_ids"].map(&:to_i) }
    expect(sent_ids).not_to include(colleagues["id"])
    expect(fake.stored_entry(colleagues["id"])["project_id"]).to eq(project.id)
    expect(fake.stored_entry(own["id"])["project_id"]).to eq(target_project.id)
  end
end

require "rails_helper"
require_relative "../../../../../support/timekeeping/fake_timekeeping"

RSpec.describe "Api::V1::TimesheetEntry::BulkActionController forwarded foreign target project", type: :request do
  let(:company) { create(:company) }
  let(:client) { create(:client, company:) }
  let(:project) { create(:project, client:, billable: true) }
  let(:admin) { create(:user, current_workspace_id: company.id) }
  let(:other_company) { create(:company) }
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
    fake.register_project(id: other_project.id, company_id: other_company.id)
    route_timekeeping_to_fake(fake, base_url:)
    TimekeepingOwnership.current.update!(owner: "timekeeping", generation: 2, handoff_step: nil)
    fake.generation = 2
    sign_in admin
  end

  it "forwarded bulk move to another company's project answers 404 and sends nothing to Timekeeping" do
    own = fake.add_entry(company_id: company.id, user_id: admin.id, project_id: project.id,
                         work_date: Date.current.iso8601)

    send_request :patch, api_v1_bulk_action_path,
      params: { ids: [own["id"]], project_id: other_project.id }, headers: auth_headers(admin)

    # The ProjectPolicy::Scope check runs before any write, so no token naming the foreign project is minted.
    expect(response).to have_http_status(:not_found)
    expect(fake.requests.none? { |request| request[:path].to_s.end_with?("/entries/bulk-move") }).to be(true)
    expect(fake.stored_entry(own["id"])["project_id"]).to eq(project.id)
  end
end

require "rails_helper"
require_relative "../../../../../support/timekeeping/fake_timekeeping"

RSpec.describe "Api::V1::TimesheetEntry::BulkActionController forwarded delete tenant boundary", type: :request do
  let(:company) { create(:company) }
  let(:client) { create(:client, company:) }
  let(:project) { create(:project, client:, billable: true) }
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
    fake.register_project(id: other_project.id, company_id: other_company.id)
    route_timekeeping_to_fake(fake, base_url:)
    TimekeepingOwnership.current.update!(owner: "timekeeping", generation: 2, handoff_step: nil)
    fake.generation = 2
    sign_in admin
  end

  it "forwarded bulk delete of own and foreign ids deletes only the own entry and answers 422 for foreign ids alone" do
    own = fake.add_entry(company_id: company.id, user_id: admin.id, project_id: project.id,
                         work_date: Date.current.iso8601)
    foreign = fake.add_entry(company_id: other_company.id, user_id: other_user.id, project_id: other_project.id,
                             work_date: Date.current.iso8601)

    send_request :delete, api_v1_bulk_action_path,
      params: { source: { ids: [foreign["id"]] } }, headers: auth_headers(admin)

    expect(response).to have_http_status(:unprocessable_content)
    expect(fake.requests.none? { |request| request[:path].to_s.end_with?("/entries/bulk-delete") }).to be(true)
    expect(fake.stored_entry(foreign["id"])["discarded_at"]).to be_nil

    send_request :delete, api_v1_bulk_action_path,
      params: { source: { ids: [own["id"], foreign["id"]] } }, headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    delete_request = fake.requests.find { |request| request[:path].to_s.end_with?("/entries/bulk-delete") }
    expect(delete_request[:path]).to include("/v1/companies/#{company.id}/entries/bulk-delete")
    expect(delete_request[:body]["entry_ids"].map(&:to_i)).to eq([own["id"]])
    expect(fake.stored_entry(own["id"])["discarded_at"]).not_to be_nil
    expect(fake.stored_entry(foreign["id"])["discarded_at"]).to be_nil
  end
end

require "rails_helper"
require_relative "../../../../../support/timekeeping/fake_timekeeping"

RSpec.describe "Api::V1::TimesheetEntry::BulkActionController#update forwarded success", type: :request do
  let(:company) { create(:company) }
  let(:admin) { create(:user, current_workspace_id: company.id) }
  let(:client) { create(:client, company:) }
  let(:source_project) { create(:project, billable: true, client:) }
  let(:target_project) { create(:project, billable: true, client:) }
  let(:fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  around { |example| with_forwarded_timekeeping_env { example.run } }

  before do
    create(:employment, company:, user: admin)
    admin.add_role :admin, company
    arrange_forwarded_timekeeping(fake, company:, users: { admin => "admin" }, project: source_project)
    fake.register_project(id: target_project.id, company_id: company.id)
    sign_in admin
  end

  # "An entry created while Timekeeping owns the data can be bulk moved before its snapshot arrives"
  it "bulk moves entries that exist only in Timekeeping, sends one bulk-move call, and answers the legacy JSON shape" do
    first_id = fake.add_entry(company_id: company.id, user_id: admin.id, project_id: source_project.id,
                              work_date: Date.current.iso8601).fetch("id")
    second_id = fake.add_entry(company_id: company.id, user_id: admin.id, project_id: source_project.id,
                               work_date: Date.current.iso8601).fetch("id")
    local_count = TimesheetEntry.count

    send_request :patch, api_v1_bulk_action_path,
      params: { ids: [first_id, second_id], project_id: target_project.id }, headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    expect(json_response["notice"]).to match("Timesheet updated")
    # The legacy answer groups entry snippets by work date; the forwarded branch keeps that shape.
    expect(json_response["entries"]).to be_a(Hash)
    rendered_ids = json_response["entries"].values.flatten.pluck("id")
    expect(rendered_ids).to contain_exactly(first_id, second_id)

    expect(fake.stored_entry(first_id)["project_id"]).to eq(target_project.id)
    expect(fake.stored_entry(second_id)["project_id"]).to eq(target_project.id)
    bulk_calls = fake.requests.select { |request| request[:method] == "POST" && request[:path].end_with?("/entries/bulk-move") }
    expect(bulk_calls.size).to eq(1)
    expect(bulk_calls.first[:body]["entry_ids"]).to contain_exactly(first_id, second_id)
    expect(TimesheetEntry.count).to eq(local_count)
  end
end

require "rails_helper"
require_relative "../../../../../support/timekeeping/fake_timekeeping"

RSpec.describe "Api::V1::TimesheetEntry::BulkActionController#update forwarded A9 skip", type: :request do
  let(:company) { create(:company) }
  let(:employee) { create(:user, current_workspace_id: company.id) }
  let(:client) { create(:client, company:) }
  let(:source_project) { create(:project, billable: true, client:) }
  let(:target_project) { create(:project, billable: true, client:) }
  let(:fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  around { |example| with_forwarded_timekeeping_env { example.run } }

  before do
    create(:employment, company:, user: employee)
    employee.add_role :employee, company
    create(:project_member, project: source_project, user: employee)
    create(:project_member, project: target_project, user: employee)
    arrange_forwarded_timekeeping(fake, company:, users: { employee => "employee" }, project: source_project)
    fake.register_project(id: target_project.id, company_id: company.id)
    sign_in employee
  end

  # "Failing entries are still skipped silently, as A9 does today."
  it "a forwarded employee bulk move skips the locked entry silently, moves the unlocked one and answers 200" do
    locked_id = fake.add_entry(company_id: company.id, user_id: employee.id, project_id: source_project.id,
                               work_date: Date.current.iso8601, locked: true).fetch("id")
    unlocked_id = fake.add_entry(company_id: company.id, user_id: employee.id, project_id: source_project.id,
                                 work_date: Date.current.iso8601, locked: false).fetch("id")

    send_request :patch, api_v1_bulk_action_path,
      params: { ids: [locked_id, unlocked_id], project_id: target_project.id }, headers: auth_headers(employee)

    expect(response).to have_http_status(:ok)
    expect(json_response["notice"]).to eq(I18n.t("timesheet_entry.update.message"))
    expect(json_response).not_to have_key("error")
    expect(fake.stored_entry(unlocked_id)["project_id"]).to eq(target_project.id)
    expect(fake.stored_entry(locked_id)["project_id"]).to eq(source_project.id)
    expect(fake.stored_entry(locked_id)["locked"]).to be(true)
  end
end

require "rails_helper"
require_relative "../../../../../support/timekeeping/fake_timekeeping"

RSpec.describe "Api::V1::TimesheetEntry::BulkActionController#destroy forwarded mixed ids", type: :request do
  let(:company) { create(:company) }
  let(:admin) { create(:user, current_workspace_id: company.id) }
  let(:project) { create(:project, billable: true, client: create(:client, company:)) }
  let(:other_company) { create(:company) }
  let(:other_user) { create(:user, current_workspace_id: other_company.id) }
  let(:other_project) { create(:project, billable: true, client: create(:client, company: other_company)) }
  let(:fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  around { |example| with_forwarded_timekeeping_env { example.run } }

  before do
    create(:employment, company:, user: admin)
    admin.add_role :admin, company
    arrange_forwarded_timekeeping(fake, company:, users: { admin => "admin" }, project:)
    fake.register_company(id: other_company.id, edit_days: other_company.timesheet_edit_days)
    fake.register_user(id: other_user.id, company_id: other_company.id, role: "admin")
    fake.register_project(id: other_project.id, company_id: other_company.id)
    sign_in admin
  end

  it "a forwarded bulk delete with own and foreign ids answers 200, deletes only the own entry and sends one bulk-delete call" do
    own_id = fake.add_entry(company_id: company.id, user_id: admin.id, project_id: project.id,
                            work_date: Date.current.iso8601).fetch("id")
    foreign_id = fake.add_entry(company_id: other_company.id, user_id: other_user.id, project_id: other_project.id,
                                work_date: Date.current.iso8601).fetch("id")

    send_request :delete, api_v1_bulk_action_path,
      params: { source: { ids: [own_id, foreign_id] } }, headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    expect(json_response["notice"]).to eq(I18n.t("timesheet_entry.destroy.message"))
    expect(fake.stored_entry(own_id)["discarded_at"]).not_to be_nil
    expect(fake.stored_entry(foreign_id)["discarded_at"]).to be_nil
    bulk_calls = fake.requests.select { |request| request[:method] == "POST" && request[:path].end_with?("/entries/bulk-delete") }
    expect(bulk_calls.size).to eq(1)
    # Only ids the scoped lookup resolved are forwarded, never the raw request ids.
    expect(bulk_calls.first[:body]["entry_ids"]).to eq([own_id])
  end
end

require "rails_helper"
require_relative "../../../../../support/timekeeping/fake_timekeeping"

RSpec.describe "Api::V1::TimesheetEntry::BulkActionController#update forwarded foreign ids", type: :request do
  let(:company) { create(:company) }
  let(:admin) { create(:user, current_workspace_id: company.id) }
  let(:project) { create(:project, billable: true, client: create(:client, company:)) }
  let(:other_company) { create(:company) }
  let(:other_user) { create(:user, current_workspace_id: other_company.id) }
  let(:other_project) { create(:project, billable: true, client: create(:client, company: other_company)) }
  let(:fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  around { |example| with_forwarded_timekeeping_env { example.run } }

  before do
    create(:employment, company:, user: admin)
    admin.add_role :admin, company
    arrange_forwarded_timekeeping(fake, company:, users: { admin => "admin" }, project:)
    fake.register_company(id: other_company.id, edit_days: other_company.timesheet_edit_days)
    fake.register_user(id: other_user.id, company_id: other_company.id, role: "admin")
    fake.register_project(id: other_project.id, company_id: other_company.id)
    sign_in admin
  end

  it "a forwarded bulk move of only another company's entry answers 422 and sends no bulk-move call" do
    foreign_id = fake.add_entry(company_id: other_company.id, user_id: other_user.id, project_id: other_project.id,
                                work_date: Date.current.iso8601).fetch("id")

    send_request :patch, api_v1_bulk_action_path,
      params: { ids: [foreign_id], project_id: project.id }, headers: auth_headers(admin)

    # A foreign id is dropped like a missing one, never answered as 404, so ids in other companies stay hidden.
    expect(response).to have_http_status(:unprocessable_content)
    expect(json_response["error"]).to eq("Failed to update timesheet entries")
    expect(fake.stored_entry(foreign_id)["project_id"]).to eq(other_project.id)
    expect(fake.requests.select { |request| request[:path].end_with?("/entries/bulk-move") }).to be_empty
  end
end

require "rails_helper"
require_relative "../../../../../support/timekeeping/fake_timekeeping"

RSpec.describe "Api::V1::TimesheetEntry::BulkActionController#update forwarded malformed id", type: :request do
  let(:company) { create(:company) }
  let(:admin) { create(:user, current_workspace_id: company.id) }
  let(:client) { create(:client, company:) }
  let(:source_project) { create(:project, billable: true, client:) }
  let(:target_project) { create(:project, billable: true, client:) }
  let(:fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  around { |example| with_forwarded_timekeeping_env { example.run } }

  before do
    create(:employment, company:, user: admin)
    admin.add_role :admin, company
    arrange_forwarded_timekeeping(fake, company:, users: { admin => "admin" }, project: source_project)
    fake.register_project(id: target_project.id, company_id: company.id)
    sign_in admin
  end

  it "a forwarded bulk move with a malformed id beside a valid one answers 200 and moves the valid entry" do
    entry_id = fake.add_entry(company_id: company.id, user_id: admin.id, project_id: source_project.id,
                              work_date: Date.current.iso8601).fetch("id")

    send_request :patch, api_v1_bulk_action_path,
      params: { ids: [entry_id, "not-an-id"], project_id: target_project.id }, headers: auth_headers(admin)

    # The legacy query dropped an id that is not a number; the forwarded branch must drop it too, not answer 500.
    expect(response).to have_http_status(:ok)
    expect(fake.stored_entry(entry_id)["project_id"]).to eq(target_project.id)
    bulk_call = fake.requests.find { |request| request[:path].end_with?("/entries/bulk-move") }
    expect(bulk_call[:body]["entry_ids"]).to eq([entry_id])
  end
end

require "rails_helper"
require_relative "../../../../../support/timekeeping/fake_timekeeping"

RSpec.describe "Api::V1::TimesheetEntry::BulkActionController#update forwarded validation skip", type: :request do
  let(:company) { create(:company) }
  let(:admin) { create(:user, current_workspace_id: company.id) }
  let(:client) { create(:client, company:) }
  let(:source_project) { create(:project, billable: true, client:) }
  let(:non_billable_project) { create(:project, billable: false, client:) }
  let(:fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  around { |example| with_forwarded_timekeeping_env { example.run } }

  before do
    create(:employment, company:, user: admin)
    admin.add_role :admin, company
    arrange_forwarded_timekeeping(fake, company:, users: { admin => "admin" }, project: source_project)
    fake.register_project(id: non_billable_project.id, company_id: company.id)
    sign_in admin
  end

  # "Failing entries are still skipped silently, as A9 does today."
  it "a forwarded bulk move of an unbilled entry to a non-billable project skips that entry silently and answers 200" do
    entry_id = fake.add_entry(company_id: company.id, user_id: admin.id, project_id: source_project.id,
                              work_date: Date.current.iso8601, bill_status: "unbilled").fetch("id")

    send_request :patch, api_v1_bulk_action_path,
      params: { ids: [entry_id], project_id: non_billable_project.id }, headers: auth_headers(admin)

    # The legacy save refuses an unbilled entry on a non-billable project and skips it; forwarded must match.
    expect(response).to have_http_status(:ok)
    expect(json_response).not_to have_key("error")
    expect(fake.stored_entry(entry_id)["project_id"]).to eq(source_project.id)
  end
end

require "rails_helper"
require_relative "../../../../../support/timekeeping/fake_timekeeping"

RSpec.describe "Api::V1::TimesheetEntry::BulkActionController#destroy forwarded handoff", type: :request do
  let(:company) { create(:company) }
  let(:admin) { create(:user, current_workspace_id: company.id) }
  let(:project) { create(:project, billable: true, client: create(:client, company:)) }
  let(:fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  around { |example| with_forwarded_timekeeping_env { example.run } }

  before do
    create(:employment, company:, user: admin)
    admin.add_role :admin, company
    arrange_forwarded_timekeeping(fake, company:, users: { admin => "admin" }, project:)
    sign_in admin
  end

  # "When `handoff_step` is set, the gateway refuses entry writes, prepares and service commands with a retryable `503 ownership_moving`."
  it "a forwarded bulk delete during a handoff answers 503 ownership_moving, sends nothing and deletes nothing" do
    entry_id = fake.add_entry(company_id: company.id, user_id: admin.id, project_id: project.id,
                              work_date: Date.current.iso8601).fetch("id")
    TimekeepingOwnership.current.update!(handoff_step: "close_admission")
    requests_before = fake.requests.size

    send_request :delete, api_v1_bulk_action_path,
      params: { source: { ids: [entry_id] } }, headers: auth_headers(admin)

    expect(response).to have_http_status(:service_unavailable)
    expect(json_response["reason"]).to eq("ownership_moving")
    expect(fake.requests.size).to eq(requests_before)
    expect(fake.stored_entry(entry_id)["discarded_at"]).to be_nil
  end
end

require "rails_helper"

RSpec.describe "Api::V1::TimesheetEntry::BulkActionController#update legacy handoff", type: :request do
  let(:company) { create(:company) }
  let(:admin) { create(:user, current_workspace_id: company.id) }
  let(:client) { create(:client, company:) }
  let(:source_project) { create(:project, billable: true, client:) }
  let(:target_project) { create(:project, billable: true, client:) }

  before do
    create(:employment, company:, user: admin)
    admin.add_role :admin, company
    sign_in admin
  end

  # "When `handoff_step` is set, the gateway refuses entry writes, prepares and service commands with a retryable `503 ownership_moving`."
  it "a legacy bulk move during a handoff answers 503 ownership_moving and moves no entry" do
    first = create(:timesheet_entry, user: admin, project: source_project, bill_status: "unbilled")
    second = create(:timesheet_entry, user: admin, project: source_project, bill_status: "unbilled")
    TimekeepingOwnership.current.update!(handoff_step: "close_admission")

    send_request :patch, api_v1_bulk_action_path,
      params: { ids: [first.id, second.id], project_id: target_project.id }, headers: auth_headers(admin)

    expect(response).to have_http_status(:service_unavailable)
    expect(json_response["reason"]).to eq("ownership_moving")
    expect(first.reload.project_id).to eq(source_project.id)
    expect(second.reload.project_id).to eq(source_project.id)
  end
end

require "rails_helper"

RSpec.describe "Api::V1::TimesheetEntry::BulkActionController forwarded id boundary", type: :request do
  around { |example| with_forwarded_timekeeping_env { example.run } }

  it "forwards a bulk move naming the own entry once and never another company's entry id" do
    fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
    company = create(:company)
    client = create(:client, company:)
    from_project = create(:project, billable: true, client:)
    to_project = create(:project, billable: true, client:)
    admin = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user: admin)
    admin.add_role :admin, company
    arrange_forwarded_timekeeping(fake, company:, users: { admin => "admin" }, project: from_project)
    fake.register_project(id: to_project.id, company_id: company.id)

    other_company = create(:company)
    other_project = create(:project, billable: true, client: create(:client, company: other_company))
    other_user = create(:user, current_workspace_id: other_company.id)
    create(:employment, company: other_company, user: other_user)
    fake.register_project(id: other_project.id, company_id: other_company.id)

    own_id = fake.add_entry(company_id: company.id, user_id: admin.id, project_id: from_project.id,
                            work_date: Date.current.iso8601)["id"]
    foreign_id = fake.add_entry(company_id: other_company.id, user_id: other_user.id, project_id: other_project.id,
                                work_date: Date.current.iso8601)["id"]

    sign_in admin
    send_request :patch, api_v1_bulk_action_path,
      params: { ids: [own_id, own_id, foreign_id], project_id: to_project.id }, headers: auth_headers(admin)

    # The id from another company is dropped like a missing one, and a
    # repeated id is sent once, so Timekeeping is never asked to decide them.
    expect(response).to have_http_status(:ok)
    bulk_calls = fake.requests.select { |request| request[:path].to_s.end_with?("/entries/bulk-move") }
    expect(bulk_calls.size).to eq(1)
    expect(bulk_calls.first[:body]["entry_ids"].map { |id| Integer(id) }).to eq([own_id])
    expect(fake.stored_entry(own_id)["project_id"]).to eq(to_project.id)
    expect(fake.stored_entry(foreign_id)["project_id"]).to eq(other_project.id)
  end
end

require "rails_helper"

RSpec.describe "Api::V1::TimesheetEntry::BulkActionController forwarded malformed id", type: :request do
  around { |example| with_forwarded_timekeeping_env { example.run } }

  it "skips a malformed id and still moves the valid entry when Timekeeping owns the data" do
    fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
    company = create(:company)
    client = create(:client, company:)
    from_project = create(:project, billable: true, client:)
    to_project = create(:project, billable: true, client:)
    admin = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user: admin)
    admin.add_role :admin, company
    arrange_forwarded_timekeeping(fake, company:, users: { admin => "admin" }, project: from_project)
    fake.register_project(id: to_project.id, company_id: company.id)
    entry_id = fake.add_entry(company_id: company.id, user_id: admin.id, project_id: from_project.id,
                              work_date: Date.current.iso8601)["id"]

    sign_in admin
    send_request :patch, api_v1_bulk_action_path,
      params: { ids: [entry_id, "not-an-id"], project_id: to_project.id }, headers: auth_headers(admin)

    # The legacy controller's where(id:) query ignores an id that is not a
    # number, so the forwarded branch must skip it too rather than fail.
    expect(response).to have_http_status(:ok)
    expect(fake.stored_entry(entry_id)["project_id"]).to eq(to_project.id)
  end
end

require "rails_helper"

RSpec.describe "Api::V1::TimesheetEntry::BulkActionController forwarded stale generation", type: :request do
  around { |example| with_forwarded_timekeeping_env { example.run } }

  it "answers 409 to a forwarded bulk move at a stale generation and leaves every entry where it was" do
    fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
    company = create(:company)
    client = create(:client, company:)
    from_project = create(:project, billable: true, client:)
    to_project = create(:project, billable: true, client:)
    admin = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user: admin)
    admin.add_role :admin, company
    arrange_forwarded_timekeeping(fake, company:, users: { admin => "admin" }, project: from_project)
    fake.register_project(id: to_project.id, company_id: company.id)
    first_id = fake.add_entry(company_id: company.id, user_id: admin.id, project_id: from_project.id,
                              work_date: Date.current.iso8601)["id"]
    second_id = fake.add_entry(company_id: company.id, user_id: admin.id, project_id: from_project.id,
                               work_date: Date.current.iso8601)["id"]
    # Timekeeping has moved on to a newer generation than the monolith's row.
    fake.generation = 3

    sign_in admin
    send_request :patch, api_v1_bulk_action_path,
      params: { ids: [first_id, second_id], project_id: to_project.id }, headers: auth_headers(admin)

    # "A generation refusal fails the whole bulk request with an error. It is not one of the silently skipped entries of A9."
    expect(response).to have_http_status(:conflict)
    expect(fake.stored_entry(first_id)["project_id"]).to eq(from_project.id)
    expect(fake.stored_entry(second_id)["project_id"]).to eq(from_project.id)
  end
end

require "rails_helper"

RSpec.describe "Api::V1::TimesheetEntry::BulkActionController forwarded handoff", type: :request do
  around { |example| with_forwarded_timekeeping_env { example.run } }

  it "refuses a forwarded bulk delete with 503 during a handoff and sends nothing to Timekeeping's bulk route" do
    fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
    company = create(:company)
    project = create(:project, billable: true, client: create(:client, company:))
    admin = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user: admin)
    admin.add_role :admin, company
    arrange_forwarded_timekeeping(fake, company:, users: { admin => "admin" }, project:)
    entry_id = fake.add_entry(company_id: company.id, user_id: admin.id, project_id: project.id,
                              work_date: Date.current.iso8601)["id"]
    TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).update_columns(handoff_step: "freeze")

    sign_in admin
    send_request :delete, api_v1_bulk_action_path, params: { source: { ids: [entry_id] } }, headers: auth_headers(admin)

    # "When `handoff_step` is set, the gateway refuses entry writes, prepares and service commands with a retryable `503 ownership_moving`."
    expect(response).to have_http_status(:service_unavailable)
    expect(fake.requests.select { |request| request[:path].to_s.end_with?("/entries/bulk-delete") }).to be_empty
    expect(fake.stored_entry(entry_id)["discarded_at"]).to be_nil
  end
end

require "rails_helper"

RSpec.describe "Api::V1::TimesheetEntry::BulkActionController forwarded validation skip", type: :request do
  around { |example| with_forwarded_timekeeping_env { example.run } }

  it "skips an unbilled forwarded entry moved to a non-billable project and still answers 200" do
    fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
    company = create(:company)
    client = create(:client, company:)
    from_project = create(:project, billable: true, client:)
    non_billable_project = create(:project, billable: false, client:)
    admin = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user: admin)
    admin.add_role :admin, company
    arrange_forwarded_timekeeping(fake, company:, users: { admin => "admin" }, project: from_project)
    fake.register_project(id: non_billable_project.id, company_id: company.id)
    entry_id = fake.add_entry(company_id: company.id, user_id: admin.id, project_id: from_project.id,
                              work_date: Date.current.iso8601, bill_status: "unbilled")["id"]

    sign_in admin
    send_request :patch, api_v1_bulk_action_path,
      params: { ids: [entry_id], project_id: non_billable_project.id }, headers: auth_headers(admin)

    # "Failing entries are still skipped silently, as A9 does today."
    # The legacy save refuses an unbilled entry on a non-billable project, so
    # the forwarded branch must leave it in place too.
    expect(response).to have_http_status(:ok)
    expect(json_response).not_to have_key("error")
    expect(fake.stored_entry(entry_id)["project_id"]).to eq(from_project.id)
  end
end

RSpec.describe "Api::V1::TimesheetEntry::BulkActionController legacy skips through the gateway", type: :request do
  let(:company) { create(:company) }
  let(:client) { create(:client, company:) }
  let(:from_project) { create(:project, billable: true, client:) }
  let(:admin) { create(:user, current_workspace_id: company.id) }

  before do
    create(:employment, company:, user: admin)
    admin.add_role :admin, company
    sign_in admin
  end

  it "a legacy bulk move to a non-billable project answers 200 and leaves the unbilled entry on its project" do
    non_billable_project = create(:project, billable: false, client:)
    entry = create(:timesheet_entry, user: admin, project: from_project, work_date: Date.current, bill_status: "unbilled")

    send_request :patch, api_v1_bulk_action_path,
      params: { ids: [entry.id], project_id: non_billable_project.id }, headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    expect(json_response).not_to have_key("error")
    expect(entry.reload.project_id).to eq(from_project.id)
  end

  it "a legacy bulk move with a malformed id beside a valid one answers 200 and moves the valid entry" do
    to_project = create(:project, billable: true, client:)
    entry = create(:timesheet_entry, user: admin, project: from_project, work_date: Date.current, bill_status: "unbilled")

    send_request :patch, api_v1_bulk_action_path,
      params: { ids: [entry.id, "not-an-id"], project_id: to_project.id }, headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    expect(entry.reload.project_id).to eq(to_project.id)
  end
end
