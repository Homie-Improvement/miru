# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Users#destroy", type: :request do
  let(:company) { create(:company, name: "Acme") }
  let(:super_admin) { create(:user, email: "hello@saeloun.com", current_workspace_id: company.id) }
  let(:target_user) { create(:user, current_workspace_id: company.id) }

  before do
    create(:employment, company:, user: super_admin)
    super_admin.add_role :admin, company
  end

  def delete_user(user, actor: super_admin)
    send_request :delete, api_v1_user_path(user), headers: auth_headers(actor)
  end

  context "when the current user is a super admin" do
    before do
      create(:employment, company:, user: target_user)
      target_user.add_role :employee, company
      sign_in super_admin
    end

    it "permanently deletes the user" do
      expect {
        delete_user(target_user)
      }.to change(User, :count).by(-1)

      expect(response).to have_http_status(:ok)
      expect(json_response["notice"]).to eq(
        I18n.t("user.super_admin_delete.success", email: target_user.email)
      )
      expect(User.exists?(target_user.id)).to be(false)
    end

    it "creates an audit record with actor and target details" do
      target_id = target_user.id
      target_email = target_user.email

      expect {
        delete_user(target_user)
      }.to change { Audited::Audit.where(action: "super_admin_delete").count }.by(1)

      audit = Audited::Audit.where(action: "super_admin_delete").last
      expect(audit.user).to eq(super_admin)
      expect(audit.auditable_id).to eq(target_id)
      expect(audit.auditable_type).to eq("User")
      expect(audit.audited_changes.symbolize_keys).to include(
        actor_id: super_admin.id,
        actor_email: super_admin.email,
        target_user_id: target_id,
        target_user_email: target_email
      )
      expect(audit.audited_changes.symbolize_keys[:occurred_at]).to be_present
    end
  end

  context "when the current user is not a super admin" do
    let(:admin_user) { create(:user, current_workspace_id: company.id) }

    before do
      create(:employment, company:, user: admin_user)
      create(:employment, company:, user: target_user)
      admin_user.add_role :admin, company
      target_user.add_role :employee, company
      sign_in admin_user
    end

    it "returns forbidden and does not delete the user" do
      expect {
        delete_user(target_user, actor: admin_user)
      }.not_to change(User, :count)

      expect(response).to have_http_status(:forbidden)
      expect(User.exists?(target_user.id)).to be(true)
    end
  end

  context "when the super admin deletes themself" do
    before { sign_in super_admin }

    it "returns forbidden and does not create an audit record" do
      audit_count = Audited::Audit.where(action: "super_admin_delete").count

      expect {
        delete_user(super_admin)
      }.not_to change(User, :count)

      expect(response).to have_http_status(:forbidden)
      expect(Audited::Audit.where(action: "super_admin_delete").count).to eq(audit_count)
    end
  end

  context "when the target user is the sole company owner" do
    before do
      create(:employment, company:, user: target_user)
      target_user.add_role :owner, company
      sign_in super_admin
    end

    it "blocks deletion until ownership is transferred or the company is deleted" do
      audit_count = Audited::Audit.where(action: "super_admin_delete").count

      expect {
        delete_user(target_user)
      }.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response["errors"]).to eq(
        I18n.t("user.super_admin_delete.sole_owner", companies: company.name)
      )
      expect(User.exists?(target_user.id)).to be(true)
      expect(Audited::Audit.where(action: "super_admin_delete").count).to eq(audit_count)
    end
  end

  # The ownership row is shared by every company and its changed_by column names
  # a person, so once a handoff has begun the refusal carries only the fixed
  # locale message: no ownership values and no company name.
  context "when a handoff has begun, the refusal body" do
    # Each state lists the values it seeds that must never reach the body.
    # Generation 2 gets no substring check: a single digit is not a useful leak test.
    refusal_body_states = {
      "owned by Timekeeping" => {
        columns: { owner: "timekeeping", handoff_step: nil, generation: 4217,
                   changed_by: "handoff-operator-7731@example.com" },
        hidden_values: ["handoff-operator-7731@example.com", "4217", "timekeeping\""]
      },
      "prepared monolith store" => {
        columns: { monolith_store: "prepared", generation: 2, changed_by: "operator-jane" },
        hidden_values: ["operator-jane", "prepared"]
      }
    }

    before do
      create(:employment, company:, user: target_user)
      target_user.add_role :employee, company
      sign_in super_admin
    end

    refusal_body_states.each do |label, state|
      it "holds only the fixed handoff message and no ownership values (#{label})" do
        TimekeepingOwnership.current.update_columns(state[:columns])
        expect(TimekeepingOwnership.current.attributes.symbolize_keys).to include(state[:columns])
        expect(User.exists?(target_user.id)).to be(true)

        delete_user(target_user)

        expect(response).to have_http_status(:unprocessable_content)
        expect(I18n.exists?("user.super_admin_delete.handoff_begun", :en)).to be(true)
        expect(json_response.keys).to eq(["errors"])
        expect(json_response["errors"]).to eq(I18n.t("user.super_admin_delete.handoff_begun"))
        (state[:hidden_values] + [company.name]).each do |value|
          expect(response.body).not_to include(value)
        end
        expect(User.exists?(target_user.id)).to be(true)
      end
    end
  end
end

# Generated by Descant: acceptance tests below.

RSpec.describe "Api::V1::Users#destroy handoff refusal for unknown users", type: :request do
  # The user lookup runs before the handoff check, so probing ids never reveals
  # the global handoff state through a 422.
  it "answers a missing user id the same way before and after a handoff has begun" do
    company = create(:company)
    super_admin = create(:user, email: "hello@saeloun.com", current_workspace_id: company.id)
    create(:employment, company:, user: super_admin)
    super_admin.add_role :admin, company
    sign_in super_admin
    missing_id = User.maximum(:id).to_i + 1000

    send_request :delete, api_v1_user_path(missing_id), headers: auth_headers(super_admin)
    legacy_status = response.status

    TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).update_columns(handoff_step: "settle")
    send_request :delete, api_v1_user_path(missing_id), headers: auth_headers(super_admin)

    expect(response.status).to eq(legacy_status)
    expect(response.status).not_to eq(422)
    expect(response.body).not_to include(I18n.t("user.super_admin_delete.handoff_begun"))
  end
end

RSpec.describe "Api::V1::Users#destroy once a timekeeping handoff has begun", type: :request do
  # "In each refused state: user destroy gives 422, writes no audit row and deletes nothing;"
  it "refuses the super admin delete in every begun state without an audit row or any deletion" do
    company = create(:company, name: "Handoff Co")
    super_admin = create(:user, email: "hello@saeloun.com", current_workspace_id: company.id)
    create(:employment, company:, user: super_admin)
    super_admin.add_role :admin, company
    # An employee with no timesheet entries, so neither the sole-owner check nor the
    # entries foreign key can be what stops the delete.
    target_user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user: target_user)
    target_user.add_role :employee, company
    sign_in super_admin

    audits = Audited::Audit.where(action: "super_admin_delete")
    baseline_audit_count = audits.count
    baseline_user_count = User.count
    expect(baseline_audit_count).to eq(0)
    expect(User.exists?(target_user.id)).to be(true)

    ownership = TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID)
    begun_states = {
      "handoff_step set" => { generation: 2, handoff_step: "settle", owner: "monolith", monolith_store: "legacy" },
      "owned by Timekeeping after the flip" => { generation: 2, handoff_step: nil, owner: "timekeeping", monolith_store: "legacy" },
      "prepared store after a rollback" => { generation: 2, handoff_step: nil, owner: "monolith", monolith_store: "prepared" },
      "legacy store at generation 2" => { generation: 2, handoff_step: nil, owner: "monolith", monolith_store: "legacy" }
    }

    begun_states.each do |label, columns|
      ownership.update_columns(columns)

      send_request :delete, api_v1_user_path(target_user), headers: auth_headers(super_admin)

      expect(response).to have_http_status(:unprocessable_content), label
      expect(json_response["errors"]).to eq(I18n.t("user.super_admin_delete.handoff_begun")), label
      expect(User.exists?(target_user.id)).to be(true), label
      expect(User.count).to eq(baseline_user_count), label
      expect(target_user.employments.count).to eq(1), label
      expect(audits.count).to eq(baseline_audit_count), label
    end
  end
end

RSpec.describe "Api::V1::Users#destroy after a Timekeeping flip", type: :request do
  let(:handoff_company) { create(:company, name: "Flip Co") }
  let(:handoff_admin) { create(:user, email: "hello@saeloun.com", current_workspace_id: handoff_company.id) }
  let(:handoff_target) { create(:user, current_workspace_id: handoff_company.id) }

  before do
    create(:employment, company: handoff_company, user: handoff_admin)
    handoff_admin.add_role :admin, handoff_company
    create(:employment, company: handoff_company, user: handoff_target)
    handoff_target.add_role :employee, handoff_company
    sign_in handoff_admin
  end

  # "`target_user.destroy!` in `app/controllers/api/v1/users_controller.rb` is refused with a clear error once a handoff has begun, in either ownership state."
  # "A refused run or request writes nothing."
  it "refuses a repeated super-admin delete after the flip to Timekeeping and persists no audit row or deletion on either attempt" do
    TimekeepingOwnership.current.update_columns(generation: 2, handoff_step: nil, owner: "timekeeping", monolith_store: "legacy")
    audit_baseline = Audited::Audit.where(action: "super_admin_delete").count
    expect(User.exists?(handoff_target.id)).to be(true)

    2.times do
      send_request :delete, api_v1_user_path(handoff_target), headers: auth_headers(handoff_admin)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response["errors"]).to eq(I18n.t("user.super_admin_delete.handoff_begun"))
    end

    expect(User.exists?(handoff_target.id)).to be(true)
    expect(Employment.where(user_id: handoff_target.id).count).to eq(1)
    expect(Audited::Audit.where(action: "super_admin_delete").count).to eq(audit_baseline)
    expect(TimekeepingOwnership.pluck(:generation, :owner, :handoff_step, :monolith_store))
      .to eq([[2, "timekeeping", nil, "legacy"]])
  end
end

RSpec.describe "Api::V1::Users#destroy with no ownership row", type: :request do
  let(:missing_row_company) { create(:company, name: "Lost Row Co") }
  let(:missing_row_admin) { create(:user, email: "hello@saeloun.com", current_workspace_id: missing_row_company.id) }
  let(:missing_row_target) { create(:user, current_workspace_id: missing_row_company.id) }

  before do
    create(:employment, company: missing_row_company, user: missing_row_admin)
    missing_row_admin.add_role :admin, missing_row_company
    create(:employment, company: missing_row_company, user: missing_row_target)
    missing_row_target.add_role :employee, missing_row_company
    sign_in missing_row_admin
  end

  # "A missing ownership row counts as begun."
  it "refuses the super-admin delete when the ownership row is missing and does not recreate the row" do
    audit_baseline = Audited::Audit.where(action: "super_admin_delete").count
    target_id = missing_row_target.id
    TimekeepingOwnership.delete_all

    send_request :delete, api_v1_user_path(missing_row_target), headers: auth_headers(missing_row_admin)

    expect(response).to have_http_status(:unprocessable_content)
    expect(json_response["errors"]).to eq(I18n.t("user.super_admin_delete.handoff_begun"))
    expect(User.exists?(target_id)).to be(true)
    expect(Audited::Audit.where(action: "super_admin_delete").count).to eq(audit_baseline)
    expect(TimekeepingOwnership.count).to eq(0)
  end
end

RSpec.describe "Api::V1::Users#destroy handoff refusal across companies", type: :request do
  # "The ownership record is one global row, so this refusal applies to every company at once."
  it "refuses a super admin deleting a user of a second company with no timekeeping data once a handoff has begun" do
    company = create(:company, name: "Acme")
    other_company = create(:company, name: "Globex")
    super_admin = create(:user, email: "hello@saeloun.com", current_workspace_id: company.id)
    create(:employment, company:, user: super_admin)
    super_admin.add_role :admin, company
    target_user = create(:user, current_workspace_id: other_company.id)
    create(:employment, company: other_company, user: target_user)
    target_user.add_role :employee, other_company
    sign_in super_admin

    TimekeepingOwnership.ensure_initial!
    TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID)
      .update_columns(owner: "timekeeping", generation: 2, handoff_step: nil)

    audit_count = Audited::Audit.where(action: "super_admin_delete").count
    expect(audit_count).to eq(0)

    send_request :delete, api_v1_user_path(target_user), headers: auth_headers(super_admin)

    expect(response).to have_http_status(:unprocessable_content)
    expect(json_response["errors"]).to eq(I18n.t("user.super_admin_delete.handoff_begun"))
    expect(User.exists?(target_user.id)).to be(true)
    expect(Audited::Audit.where(action: "super_admin_delete").count).to eq(audit_count)
  end
end

RSpec.describe "Api::V1::Users#destroy in the initial legacy ownership state", type: :request do
  it "still deletes the user and writes one audit row in the initial legacy ownership state" do
    legacy_company = create(:company, name: "Legacy Co")
    legacy_super_admin = create(:user, email: "hello@saeloun.com", current_workspace_id: legacy_company.id)
    legacy_target = create(:user, current_workspace_id: legacy_company.id)
    create(:employment, company: legacy_company, user: legacy_super_admin)
    legacy_super_admin.add_role :admin, legacy_company
    create(:employment, company: legacy_company, user: legacy_target)
    legacy_target.add_role :employee, legacy_company
    sign_in legacy_super_admin

    TimekeepingOwnership.current.update_columns(generation: 1, handoff_step: nil, owner: "monolith", monolith_store: "legacy")
    audit_count = Audited::Audit.where(action: "super_admin_delete").count

    # "The initial legacy state still seeds and destroys as today"
    send_request :delete, api_v1_user_path(legacy_target), headers: auth_headers(legacy_super_admin)

    expect(response).to have_http_status(:ok)
    expect(json_response["notice"]).to eq(I18n.t("user.super_admin_delete.success", email: legacy_target.email))
    expect(User.exists?(legacy_target.id)).to be(false)
    expect(Audited::Audit.where(action: "super_admin_delete").count).to eq(audit_count + 1)
    expect(TimekeepingOwnership.pluck(:generation, :handoff_step, :owner, :monolith_store))
      .to eq([[1, nil, "monolith", "legacy"]])
  end

  # The audit row and the delete share one transaction, so a delete that fails
  # leaves no audit row claiming the user was deleted.
  it "rolls back the audit row when the permanent delete fails" do
    rollback_company = create(:company, name: "Rollback Co")
    rollback_super_admin = create(:user, email: "hello@saeloun.com", current_workspace_id: rollback_company.id)
    rollback_target = create(:user, current_workspace_id: rollback_company.id)
    create(:employment, company: rollback_company, user: rollback_super_admin)
    rollback_super_admin.add_role :admin, rollback_company
    create(:employment, company: rollback_company, user: rollback_target)
    rollback_target.add_role :employee, rollback_company
    sign_in rollback_super_admin

    allow(User).to receive(:find).and_call_original
    allow(User).to receive(:find).with(rollback_target.id.to_s).and_return(rollback_target)
    allow(rollback_target).to receive(:destroy!).and_raise(ActiveRecord::RecordNotDestroyed, "delete failed")
    audit_count = Audited::Audit.where(action: "super_admin_delete").count
    expect(audit_count).to eq(0)

    expect {
      send_request :delete, api_v1_user_path(rollback_target), headers: auth_headers(rollback_super_admin)
    }.to raise_error(ActiveRecord::RecordNotDestroyed, "delete failed")

    expect(User.exists?(rollback_target.id)).to be(true)
    expect(Audited::Audit.where(action: "super_admin_delete").count).to eq(audit_count)
  end
end

RSpec.describe "Api::V1::Users#destroy refusal order during a handoff", type: :request do
  # The issue does not order the handoff refusal against authorization or the sole-owner refusal.
  # The plan checks the handoff after both, so global handoff state never reaches a caller who could
  # not delete anyway, and the sole-owner message wins when both apply.
  it "keeps 403 for a non-super-admin and the sole-owner message for a sole owner once a handoff has begun" do
    company = create(:company, name: "Acme")
    super_admin = create(:user, email: "hello@saeloun.com", current_workspace_id: company.id)
    admin = create(:user, current_workspace_id: company.id)
    owner = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user: super_admin)
    super_admin.add_role :admin, company
    create(:employment, company:, user: admin)
    admin.add_role :admin, company
    create(:employment, company:, user: owner)
    owner.add_role :owner, company
    TimekeepingOwnership.current.update_columns(handoff_step: "settle")

    sign_in admin
    send_request :delete, api_v1_user_path(owner), headers: auth_headers(admin)
    expect(response).to have_http_status(:forbidden)

    sign_in super_admin
    send_request :delete, api_v1_user_path(owner), headers: auth_headers(super_admin)
    expect(response).to have_http_status(:unprocessable_content)
    expect(json_response["errors"]).to eq(
      I18n.t("user.super_admin_delete.sole_owner", companies: company.name)
    )
    expect(User.exists?(owner.id)).to be(true)
  end

  # The handoff check runs only after authorization, so a caller who could not
  # delete anyway cannot read the global handoff state from the response.
  it "keeps returning forbidden to a non-super-admin once a handoff has begun, never the handoff refusal" do
    company = create(:company)
    admin_user = create(:user, current_workspace_id: company.id)
    target_user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user: admin_user)
    create(:employment, company:, user: target_user)
    admin_user.add_role :admin, company
    target_user.add_role :employee, company
    sign_in admin_user

    TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).update_columns(handoff_step: "close_admission")
    audit_count = Audited::Audit.where(action: "super_admin_delete").count
    expect(User.exists?(target_user.id)).to be(true)

    send_request :delete, api_v1_user_path(target_user), headers: auth_headers(admin_user)

    expect(response).to have_http_status(:forbidden)
    expect(response.body).not_to include(I18n.t("user.super_admin_delete.handoff_begun"))
    expect(User.exists?(target_user.id)).to be(true)
    expect(Audited::Audit.where(action: "super_admin_delete").count).to eq(audit_count)
  end
end
