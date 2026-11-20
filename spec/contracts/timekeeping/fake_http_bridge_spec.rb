# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimekeepingContract::FakeHttpBridge do
  # "Every direct caller of route_timekeeping_to_fake (agent_spec.rb, entry_write_client_spec.rb, gateway specs)
  # skips routing to the fake when TimekeepingRegressionAdapter.current is non-nil, and a spec with the adapter
  # running shows no requests routed to the fake."
  context "with the live adapter running" do
    let(:bridge_live_base_url) { "http://127.0.0.1:4999" }

    before do
      allow(TimekeepingRegressionAdapter).to receive(:current)
        .and_return(double("live adapter instance", base_url: bridge_live_base_url))
    end

    # The live app's own address is included because a stub there would answer live traffic from the fake.
    # No stub matching either host means no request to them can be answered by the fake.
    it "route_timekeeping_to_fake registers no stub for any host it is given" do
      bridge_fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
      bridge_base_urls = ["http://timekeeping.test", bridge_live_base_url]
      stubs_before = WebMock::StubRegistry.instance.request_stubs.size

      bridge_base_urls.each { |base_url| route_timekeeping_to_fake(bridge_fake, base_url:) }

      expect(WebMock::StubRegistry.instance.request_stubs.size).to eq(stubs_before)
      bridge_base_urls.each do |base_url|
        signature = WebMock::RequestSignature.new(:get, "#{base_url}/api/v1/entries")
        expect(WebMock::StubRegistry.instance.registered_request?(signature)).to be_nil
      end
    end
  end

  # Without the adapter, routing must work as before: every fake-backed spec depends on it.
  context "with no adapter running" do
    before { allow(TimekeepingRegressionAdapter).to receive(:current).and_return(nil) }

    it "route_timekeeping_to_fake registers one stub and the fake answers a real client request" do
      bridge_company = create(:company)
      bridge_project = create(:project, billable: true, client: create(:client, company: bridge_company))
      bridge_admin = create(:user, current_workspace_id: bridge_company.id)
      create(:employment, company: bridge_company, user: bridge_admin)
      bridge_admin.add_role :admin, bridge_company
      bridge_fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
      bridge_fake.register_company(id: bridge_company.id, edit_days: bridge_company.timesheet_edit_days)
      bridge_fake.register_project(id: bridge_project.id, company_id: bridge_company.id)
      bridge_fake.register_user(id: bridge_admin.id, company_id: bridge_company.id, role: "admin")
      entry = bridge_fake.add_entry(company_id: bridge_company.id, user_id: bridge_admin.id,
                                    project_id: bridge_project.id, work_date: Date.current.iso8601)
      stubs_before = WebMock::StubRegistry.instance.request_stubs.size

      route_timekeeping_to_fake(bridge_fake, base_url: "http://timekeeping.test")

      expect(WebMock::StubRegistry.instance.request_stubs.size).to eq(stubs_before + 1)
      entries = with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV, timekeeping_key_pair.to_pem) do
        Timekeeping::EntryApiClient.new(base_url: "http://timekeeping.test").list_entries(
          company_id: bridge_company.id, user_id: bridge_admin.id, from: Date.current - 1, to: Date.current + 1
        )
      end
      expect(entries.pluck("id")).to eq([entry.fetch("id")])
      expect(bridge_fake.requests.size).to eq(1)
    end
  end
end
