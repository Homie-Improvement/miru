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
      "missing_project_ids" => [22]
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

  it "refuses ids that are not Integers before building a request URL" do
    expect { client.fetch(company_id: "5/../x", project_ids: []) }.to raise_error(ArgumentError)
    expect { client.fetch(company_id: 5, project_ids: ["1&x=2"]) }.to raise_error(ArgumentError)
    expect(a_request(:any, /.*/)).not_to have_been_made
  end
end
