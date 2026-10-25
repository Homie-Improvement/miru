# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::ReferenceFacts do
  let(:company_a) { create(:company, timesheet_edit_days: 7) }
  let(:company_b) { create(:company, timesheet_edit_days: 30) }
  let(:project_a) { create(:project, client: create(:client, company: company_a), billable: true) }
  let(:project_b) { create(:project, client: create(:client, company: company_b), billable: false) }
  let(:shared_user) { create(:user) }
  let(:a_only_user) { create(:user) }
  let(:b_only_user) { create(:user) }

  before do
    create(:employment, company: company_a, user: shared_user)
    create(:employment, company: company_b, user: shared_user)
    create(:employment, company: company_a, user: a_only_user)
    create(:employment, company: company_b, user: b_only_user)
    shared_user.add_role(:admin, company_a)
    shared_user.add_role(:manager, company_b)
    b_only_user.add_role(:owner, company_b)
    create(:project_member, project: project_a, user: shared_user)
    create(:project_member, project: project_b, user: b_only_user)
  end

  def facts_for_a(project_ids)
    described_class.call(company: company_a, project_ids:)
  end

  it "reports another company's project as missing and carries none of its facts" do
    facts = facts_for_a([project_a.id, project_b.id])

    expect(facts[:projects].pluck(:id)).to eq([project_a.id])
    expect(facts[:missing_project_ids]).to eq([project_b.id])
    serialized = JSON.generate(facts)
    expect(serialized).not_to include(%("company_id":#{company_b.id}))
    expect(facts[:projects].flat_map { |project| project[:member_user_ids] }).not_to include(b_only_user.id)
    expect(facts[:projects].pluck(:billable)).to eq([true])
  end

  it "reports a nonexistent project id the same way as a foreign one" do
    nonexistent_id = Project.maximum(:id).to_i + 1000
    foreign = facts_for_a([project_b.id])
    nonexistent = facts_for_a([nonexistent_id])

    expect(foreign.except(:missing_project_ids)).to eq(nonexistent.except(:missing_project_ids))
    expect(foreign[:missing_project_ids]).to eq([project_b.id])
    expect(nonexistent[:missing_project_ids]).to eq([nonexistent_id])
    expect(foreign[:projects]).to eq([])
  end

  it "gives a user in two companies only the named company's role" do
    users = facts_for_a([]).fetch(:users).to_h { |user| [user[:id], user[:role]] }

    expect(users[shared_user.id]).to eq("admin")
    expect(described_class.call(company: company_b, project_ids: [])[:users])
      .to include({ id: shared_user.id, role: "manager" })
  end

  it "leaves out users who are not employed in the named company" do
    user_ids = facts_for_a([])[:users].pluck(:id)

    expect(user_ids).to contain_exactly(shared_user.id, a_only_user.id)
    expect(user_ids).not_to include(b_only_user.id)
  end

  it "gives a user with no role in the company the default employee role" do
    expect(facts_for_a([])[:users]).to include({ id: a_only_user.id, role: "employee" })
  end

  it "leaves out users whose employment in the company is discarded" do
    company_a.employments.find_by(user: a_only_user).discard!

    expect(facts_for_a([])[:users].pluck(:id)).not_to include(a_only_user.id)
  end

  it "does not report a discarded project" do
    project_a.discard!

    facts = facts_for_a([project_a.id])

    expect(facts[:projects]).to eq([])
    expect(facts[:missing_project_ids]).to eq([project_a.id])
  end

  it "does not report a discarded membership" do
    ProjectMember.find_by(project: project_a, user: shared_user).discard!

    expect(facts_for_a([project_a.id])[:projects].first[:member_user_ids]).to eq([])
  end

  it "returns the named company's edit window and billable values" do
    facts = facts_for_a([project_a.id])

    expect(facts).to include(company_id: company_a.id, edit_days: 7)
    expect(facts[:projects]).to eq(
      [{ id: project_a.id, company_id: company_a.id, billable: true, member_user_ids: [shared_user.id] }]
    )
  end

  it "holds no pay rate, email or name" do
    serialized = JSON.generate(facts_for_a([project_a.id]))

    expect(serialized).not_to include("hourly_rate")
    expect(serialized).not_to include(shared_user.email)
    expect(serialized).not_to include(shared_user.first_name)
    expect(serialized).not_to include(project_a.name)
  end
end
