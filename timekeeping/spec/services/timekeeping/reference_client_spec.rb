# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

RSpec.describe Timekeeping::ReferenceClient do
  let(:base_url) { "http://monolith.test" }
  let(:service_token) { "reference-client-spec-service-token" }
  let(:client) { described_class.new(base_url:, service_token:) }
  let(:reference_url) { "#{base_url}/internal/v1/companies/5/reference" }
  let(:facts_body) do
    {
      "company_id" => 5,
      "edit_days" => 7,
      "users" => [{ "id" => 11, "role" => "owner" }, { "id" => 12, "role" => "employee" }],
      "projects" => [{ "id" => 21, "company_id" => 5, "billable" => true, "member_user_ids" => [12] }],
      "missing_project_ids" => [22],
      "agents" => [{ "id" => 31, "user_id" => 12 }]
    }
  end

  def stub_reference(project_ids: "21,22", status: 200, body: facts_body.to_json)
    stub_request(:get, reference_url).with(query: { "project_ids" => project_ids }).to_return(status:, body:)
  end

  def fetch_facts(project_ids: [21, 22])
    client.fetch(company_id: 5, project_ids:)
  end

  it "keeps every response field reference.yml lists, so none is dropped silently" do
    contract = YAML.safe_load_file(Rails.root.join("../contracts/timekeeping/reference.yml"))

    expect(described_class::Facts.members.map(&:to_s)).to eq(contract.fetch("response_fields"))
    expect(described_class::User.members.map(&:to_s)).to eq(contract.fetch("user_fields"))
    expect(described_class::Project.members.map(&:to_s)).to eq(contract.fetch("project_fields"))
    expect(described_class::Agent.members.map(&:to_s)).to eq(contract.fetch("agent_fields"))
  end

  it "returns edit_days, the users with their roles, the projects and the missing project ids" do
    stub_reference

    facts = fetch_facts

    expect(facts.company_id).to eq(5)
    expect(facts.edit_days).to eq(7)
    expect(facts.users).to eq([described_class::User.new(id: 11, role: "owner"),
                               described_class::User.new(id: 12, role: "employee")])
    expect(facts.user_ids).to eq([11, 12])
    expect(facts.projects).to eq([described_class::Project.new(id: 21, company_id: 5, billable: true, member_user_ids: [12])])
    expect(facts.missing_project_ids).to eq([22])
    expect(facts.agents).to eq([described_class::Agent.new(id: 31, user_id: 12)])
  end

  it "calls the configured host with the service token and the requested project ids" do
    stub = stub_reference

    fetch_facts

    expect(stub.with(headers: { "Authorization" => "Bearer #{service_token}" })).to have_been_requested.once
  end

  it "sends an empty project_ids list when the write names no project" do
    stub = stub_reference(project_ids: "", body: facts_body.merge("projects" => [], "missing_project_ids" => []).to_json)

    expect(fetch_facts(project_ids: []).projects).to be_empty
    expect(stub).to have_been_requested.once
  end

  it "connects and reads with 2-second timeouts" do
    stub_reference
    allow(Net::HTTP).to receive(:start).and_call_original

    fetch_facts

    expect(client.open_timeout).to eq(2)
    expect(client.read_timeout).to eq(2)
    expect(Net::HTTP).to have_received(:start)
      .with("monolith.test", 80, hash_including(open_timeout: 2, read_timeout: 2))
  end

  it "makes a new request on every fetch, so nothing is cached" do
    stub = stub_reference

    2.times { fetch_facts }

    expect(stub).to have_been_requested.twice
  end

  it "reads the host and token from the environment when configured for the service" do
    stub = stub_reference
    allow(Timekeeping::Environment).to receive_messages(monolith_reference_url: base_url, service_token:)

    described_class.configured.fetch(company_id: 5, project_ids: [21, 22])

    expect(stub.with(headers: { "Authorization" => "Bearer #{service_token}" })).to have_been_requested.once
  end

  describe "when the facts cannot be read" do
    it "raises Unavailable on a timeout" do
      stub_request(:get, reference_url).with(query: hash_including({})).to_timeout

      expect { fetch_facts }.to raise_error(described_class::Unavailable)
    end

    it "raises Unavailable when the connection is refused" do
      stub_request(:get, reference_url).with(query: hash_including({})).to_raise(Errno::ECONNREFUSED)

      expect { fetch_facts }.to raise_error(described_class::Unavailable)
    end

    it "raises Unavailable on a 500 and on a 404" do
      [500, 404].each do |status|
        stub_reference(status:, body: { reason: "not_found" }.to_json)

        expect { fetch_facts }.to raise_error(described_class::Unavailable)
      end
    end

    it "raises Unavailable on malformed JSON" do
      stub_reference(body: "{not json")

      expect { fetch_facts }.to raise_error(described_class::Unavailable)
    end

    it "raises Unavailable when a field reference.yml lists is missing" do
      stub_reference(body: facts_body.except("users").to_json)

      expect { fetch_facts }.to raise_error(described_class::Unavailable)
    end

    it "raises Unavailable when the facts belong to another company" do
      stub_reference(body: facts_body.merge("company_id" => 6).to_json)

      expect { fetch_facts }.to raise_error(described_class::Unavailable)
    end

    it "raises Unavailable without a request when the host is not configured" do
      unconfigured = described_class.new(base_url: nil, service_token:)

      expect { unconfigured.fetch(company_id: 5, project_ids: []) }.to raise_error(described_class::Unavailable)
      expect(a_request(:any, /.*/)).not_to have_been_made
    end

    it "raises Unavailable without a request when the service token is not configured" do
      tokenless = described_class.new(base_url:, service_token: nil)

      expect { tokenless.fetch(company_id: 5, project_ids: []) }.to raise_error(described_class::Unavailable)
      expect(a_request(:any, /.*/)).not_to have_been_made
    end
  end

  it "reads an arranged agent only from its own company's stubbed reference facts" do
    arrange = TimekeepingProviderArrange.new(signing_key: TimekeepingProviderArrange.signing_key, service_token:)
    company = arrange.company
    other_company = arrange.company
    owner = arrange.user(company:, role: "owner")
    agent = arrange.agent(company:, user: owner)
    arrange.stub_reference
    arranged_client = described_class.new(base_url: TimekeepingProviderArrange::REFERENCE_URL, service_token:)

    expect(arranged_client.fetch(company_id: company, project_ids: []).agent_owners).to eq(agent => owner)
    expect(arranged_client.fetch(company_id: other_company, project_ids: []).agents).to eq([])
  end

  it "refuses ids that are not Integers before building a request URL" do
    expect { client.fetch(company_id: "5/../x", project_ids: []) }.to raise_error(ArgumentError)
    expect { client.fetch(company_id: 5, project_ids: ["1&x=2"]) }.to raise_error(ArgumentError)
    expect(a_request(:any, /.*/)).not_to have_been_made
  end
end

# Generated by Descant: acceptance tests below.
RSpec.describe Timekeeping::ReferenceClient, "agents" do
  let(:agents_reference_url) { "http://monolith.test/internal/v1/companies/5/reference" }
  let(:agents_client) { described_class.new(base_url: "http://monolith.test", service_token: "agents-spec-token") }
  let(:agents_base_body) do
    { "company_id" => 5, "edit_days" => 7, "users" => [{ "id" => 11, "role" => "owner" }],
      "projects" => [], "missing_project_ids" => [] }
  end

  def stub_agents_reference(body)
    stub_request(:get, agents_reference_url).with(query: { "project_ids" => "" })
      .to_return(status: 200, body: body.to_json)
  end

  it "returns the company's agents with their users and maps each agent id to its user id" do
    stub_agents_reference(agents_base_body.merge(
      "agents" => [{ "id" => 31, "user_id" => 11 }, { "id" => 32, "user_id" => 12 }]
    ))

    facts = agents_client.fetch(company_id: 5, project_ids: [])

    expect(facts.agents).to eq([described_class::Agent.new(id: 31, user_id: 11), described_class::Agent.new(id: 32, user_id: 12)])
    expect(facts.agent_owners).to eq({ 31 => 11, 32 => 12 })
  end

  # A lenient parse would let a write skip the agent check and commit an entry the monolith projection refuses,
  # which the issue says "holds back every later delivery". The write is refused (503 reference_unavailable).
  it "raises Unavailable when the agents list is missing, not a list, or holds an agent whose id or user_id is missing or not an Integer" do
    malformed_bodies = [
      agents_base_body,
      agents_base_body.merge("agents" => nil),
      agents_base_body.merge("agents" => "not a list"),
      agents_base_body.merge("agents" => { "id" => 31, "user_id" => 11 }),
      agents_base_body.merge("agents" => ["31"]),
      agents_base_body.merge("agents" => [{ "id" => 31 }]),
      agents_base_body.merge("agents" => [{ "id" => 31, "user_id" => nil }]),
      agents_base_body.merge("agents" => [{ "id" => 31, "user_id" => "11" }]),
      agents_base_body.merge("agents" => [{ "id" => "31", "user_id" => 11 }])
    ]

    malformed_bodies.each do |body|
      stub_agents_reference(body)

      expect { agents_client.fetch(company_id: 5, project_ids: []) }
        .to raise_error(described_class::Unavailable), "accepted #{body.inspect}"
    end
  end
end
