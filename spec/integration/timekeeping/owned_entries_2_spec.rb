# frozen_string_literal: true

require "rails_helper"

RSpec.describe "owned_entry lock state in the legacy state", committed_data: true, owner_state: "legacy" do
  it "owned_entry in the legacy state reads a locked fixture locked" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role(:admin, company)
    project = create(:project, billable: true, client: create(:client, company:))

    locked_id, open_id = arrange_owned_entries(
      [{ company:, user:, project:, note: "legacy locked", locked: true },
       { company:, user:, project:, note: "legacy open" }], state: "legacy"
    )

    # "locked fixtures still read locked in the legacy and rollback states"
    expect(owned_entry(locked_id, state: "legacy")["locked"]).to be(true)
    expect(owned_entry(open_id, state: "legacy")["locked"]).to be(false)
  end
end
