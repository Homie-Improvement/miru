# frozen_string_literal: true

require "rails_helper"
require "net/http"
require "socket"

# Boots a real Timekeeping server, so it runs only when TIMEKEEPING_LIVE=1 and
# TIMEKEEPING_DATABASE_URL names a test database under both of its readings.
RSpec.describe "TimekeepingLiveInstance generation and port", :without_transaction, committed_data: true do
  before(:all) do
    skip "Set TIMEKEEPING_LIVE=1 to boot a real Timekeeping server" unless ENV["TIMEKEEPING_LIVE"] == "1"
    begin
      TestDatabaseGuard.require_test_database_url!(ENV.fetch("TIMEKEEPING_DATABASE_URL", nil))
    rescue TestDatabaseGuard::NotATestDatabase
      skip "Set TIMEKEEPING_DATABASE_URL to a URL whose libpq and Active Record names both end in _test"
    end

    WebMock.disable_net_connect!(allow_localhost: true)
    probe = TCPServer.new("127.0.0.1", 0)
    @chosen_port = probe.addr[1]
    probe.close
    @reference = TimekeepingLiveInstance::ReferenceStub.new
    @timekeeping = TimekeepingLiveInstance.start(reference_stub: @reference, admission_generation: 2, port: @chosen_port)
    @reference.service_token = @timekeeping.service_token
  end

  after(:all) { @timekeeping&.stop }

  # "`start(reference_stub:, admission_generation: 2, port: <a free port picked by the test>)` admits generation 2,
  # answers an HTTP request at `http://127.0.0.1:<that port>`, and `write_entry` sends `Ownership-Generation: 2`."
  it "admits generation 2 on the chosen port and accepts write_entry only under generation 2" do
    WebMock.disable_net_connect!(allow_localhost: true)
    expect(@timekeeping.base_url).to eq("http://127.0.0.1:#{@chosen_port}")

    metrics = Net::HTTP::Get.new(URI("http://127.0.0.1:#{@chosen_port}/internal/v1/metrics"))
    metrics["Authorization"] = "Bearer #{@timekeeping.service_token}"
    answer = Net::HTTP.start("127.0.0.1", @chosen_port) { |http| http.request(metrics) }
    expect(answer).to be_a(Net::HTTPOK)

    company = create(:company)
    user = create(:user)
    create(:employment, company:, user:)
    user.add_role(:owner, company)
    project = create(:project, client: create(:client, company:))
    token = Timekeeping::UserToken.mint(user:, company:, project_ids: [project.id], private_key: @timekeeping.private_key)
    body = { "project_id" => project.id, "work_date" => Date.current.iso8601, "duration" => 30.0,
             "note" => "Live generation check", "source" => "manual", "source_metadata" => {} }

    expect(@timekeeping.write_entry(company_id: company.id, token:, body:)).to be_a(Net::HTTPSuccess)

    # The same write sent at generation 1 must be refused, which proves generation 2 is the admitted one.
    stale = Net::HTTP::Post.new(URI("http://127.0.0.1:#{@chosen_port}/v1/companies/#{company.id}/entries"))
    stale["Authorization"] = "Bearer #{token}"
    stale["Content-Type"] = "application/json"
    stale["Ownership-Generation"] = "1"
    stale["Idempotency-Key"] = SecureRandom.uuid
    stale.body = JSON.generate(body)
    stale_answer = Net::HTTP.start("127.0.0.1", @chosen_port) { |http| http.request(stale) }
    expect(stale_answer).not_to be_a(Net::HTTPSuccess)
  end
end
