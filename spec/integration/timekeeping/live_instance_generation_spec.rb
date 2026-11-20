# frozen_string_literal: true

require "rails_helper"
require "net/http"
require "socket"

# Boots one real Timekeeping server admitted at generation 2 on a port this
# spec picks. It needs the service's bundle and a Timekeeping test database,
# so it runs only when TIMEKEEPING_LIVE=1; the URL must pass the two-reading
# guard before anything starts, because db:prepare and the admit runner write
# to the database it names.
RSpec.describe "TimekeepingLiveInstance at a chosen generation and port", :without_transaction, committed_data: true do
  before(:all) do
    skip "Set TIMEKEEPING_LIVE=1 to boot a real Timekeeping server" unless ENV["TIMEKEEPING_LIVE"] == "1"
    url = ENV.fetch("TIMEKEEPING_DATABASE_URL", nil)
    skip "Set TIMEKEEPING_DATABASE_URL to a Timekeeping test database" if url.to_s.strip.empty?
    begin
      TestDatabaseGuard.require_test_database_url!(url)
    rescue TestDatabaseGuard::NotATestDatabase
      skip "TIMEKEEPING_DATABASE_URL must name a database whose libpq and Active Record names end in _test"
    end

    WebMock.disable_net_connect!(allow_localhost: true)
    probe = TCPServer.new("127.0.0.1", 0)
    @chosen_port = probe.addr[1]
    probe.close
    @reference = TimekeepingLiveInstance::ReferenceStub.new
    @timekeeping = TimekeepingLiveInstance.start(reference_stub: @reference, admission_generation: 2,
                                                 port: @chosen_port, database_url: url)
    @reference.service_token = @timekeeping.service_token
  end

  after(:all) { @timekeeping&.stop }

  it "a live instance started on a port the test picked answers at http://127.0.0.1 on that port" do
    # "an instance started with an explicit `port:` answers at `http://127.0.0.1:<port>`"
    expect(@timekeeping.base_url).to eq("http://127.0.0.1:#{@chosen_port}")
    request = Net::HTTP::Get.new(URI("http://127.0.0.1:#{@chosen_port}/internal/v1/metrics"))
    request["Authorization"] = "Bearer #{@timekeeping.service_token}"
    response = Net::HTTP.start("127.0.0.1", @chosen_port) { |http| http.request(request) }

    expect(response).to be_a(Net::HTTPOK)
  end

  it "a live instance admitted at generation 2 accepts a write_entry that sends Ownership-Generation 2" do
    WebMock.disable_net_connect!(allow_localhost: true)
    company = create(:company)
    user = create(:user)
    create(:employment, company:, user:)
    user.add_role(:owner, company)
    project = create(:project, client: create(:client, company:))
    token = Timekeeping::UserToken.mint(user:, company:, project_ids: [project.id],
                                        private_key: @timekeeping.private_key)
    body = { "project_id" => project.id, "work_date" => Date.current.iso8601, "duration" => 45.0,
             "note" => "Live generation check", "source" => "manual", "source_metadata" => {} }

    response = @timekeeping.write_entry(company_id: company.id, token:, body:)

    # "`TimekeepingLiveInstance.start(reference_stub:, admission_generation: 2)` admits generation 2 and `write_entry` sends `Ownership-Generation: 2`"
    # The service refuses a write whose generation differs from the admitted one, so a 201 shows generation 2 was admitted.
    expect(response.code.to_i).to eq(201)
    expect(a_request(:post, %r{/v1/companies/#{company.id}/entries\z})
      .with(headers: { "Ownership-Generation" => "2" })).to have_been_made.once
  end
end
