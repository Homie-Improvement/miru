# frozen_string_literal: true

require "rails_helper"
require "yaml"

RSpec.describe "Timekeeping entry reads" do
  let(:company_a) { 1 }
  let(:company_b) { 2 }
  let(:employee_id) { 7 }
  let(:colleague_id) { 8 }
  let(:employee_token) { mint_token({ sub: employee_id, company_id: company_a, role: "employee" }) }
  let(:owner_token) { mint_token({ sub: 9, company_id: company_a, role: "owner" }) }
  let(:contract_entry_fields) do
    YAML.load_file(Rails.root.join("../contracts/timekeeping/entry_api.yml")).dig("response", "entry_fields")
  end

  around do |example|
    with_timekeeping_env(Timekeeping::Environment::TOKEN_PUBLIC_KEY => rsa_key_pair.public_key.to_pem) { example.run }
  end

  def create_reads_spec_entry(company_id: company_a, user_id: employee_id, **attributes)
    Entry.create!(
      company_id:, user_id:, project_id: 10, work_date: Date.new(2026, 1, 5),
      duration: 60.0, note: "work", bill_status: "unbilled", **attributes
    )
  end

  def reserve_entry(entry, state)
    Reservation.create!(
      company_id: entry.company_id, entry_id: entry.id, invoice_id: 1, state:,
      disposition: "active", operation_id: SecureRandom.uuid
    )
  end

  def list_ids(token, query = {})
    get "/v1/companies/#{company_a}/entries", params: query, headers: { "Authorization" => "Bearer #{token}" }
    expect(response).to have_http_status(:ok)
    response.parsed_body.fetch("entries").pluck("id")
  end

  def show_body(entry, token = owner_token)
    get "/v1/companies/#{company_a}/entries/#{entry.id}", headers: { "Authorization" => "Bearer #{token}" }
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  describe "A1 scope on the list" do
    let!(:own_entries) { [create_reads_spec_entry, create_reads_spec_entry(work_date: Date.new(2026, 1, 6))] }
    let!(:colleague_entry) { create_reads_spec_entry(user_id: colleague_id) }
    let!(:other_company_entry) { create_reads_spec_entry(company_id: company_b) }

    it "gives an employee exactly their own entries" do
      expect(list_ids(employee_token)).to match_array(own_entries.map(&:id))
    end

    it "gives an employee who asks for a colleague's user_id an empty list" do
      expect(list_ids(employee_token, user_id: colleague_id)).to eq([])
    end

    it "gives an owner exactly the whole company's entries" do
      expect(list_ids(owner_token)).to match_array(own_entries.map(&:id) + [colleague_entry.id])
    end

    it "lets user_id and project_id narrow an owner's list, never widen it past the company" do
      expect(list_ids(owner_token, user_id: colleague_id)).to eq([colleague_entry.id])
      expect(list_ids(owner_token, project_id: 10, user_id: other_company_entry.user_id))
        .to match_array(own_entries.map(&:id))
      expect(list_ids(owner_token, project_id: 11)).to eq([])
    end

    it "keeps from and to inclusive" do
      expect(list_ids(owner_token, from: "2026-01-06", to: "2026-01-06")).to eq([own_entries.last.id])
    end

    it "returns nothing for a filter of the wrong shape rather than ignoring it" do
      expect(list_ids(owner_token, user_id: "7abc")).to eq([])
      expect(list_ids(owner_token, from: "2026-02-30")).to eq([])
      expect(list_ids(owner_token, to: "yesterday")).to eq([])
    end

    it "ignores empty filters" do
      expect(list_ids(owner_token, user_id: "", from: "")).to match_array(own_entries.map(&:id) + [colleague_entry.id])
    end
  end

  describe "response body" do
    it "serves exactly the contract's entry fields on show and under entries on list" do
      entry = create_reads_spec_entry

      expect(show_body(entry).keys).to match_array(contract_entry_fields)
      get "/v1/companies/#{company_a}/entries", headers: { "Authorization" => "Bearer #{owner_token}" }
      expect(response.parsed_body.keys).to eq(["entries"])
      expect(response.parsed_body["entries"].first.keys).to match_array(contract_entry_fields)
    end

    it "returns the stored float duration and string bill status unchanged" do
      body = show_body(create_reads_spec_entry(duration: 1.25, bill_status: "unbilled"))

      expect(body).to include("duration" => 1.25, "bill_status" => "unbilled", "company_id" => company_a)
    end
  end

  describe "locked" do
    let!(:unreserved) { create_reads_spec_entry(locked: true) }
    let!(:provisional) { create_reads_spec_entry(locked: false).tap { |entry| reserve_entry(entry, "provisional") } }
    let!(:committed) { create_reads_spec_entry(locked: false).tap { |entry| reserve_entry(entry, "committed") } }

    it "follows reservation rows on show, not the stored column" do
      expect(show_body(unreserved)["locked"]).to be(false)
      expect(show_body(provisional)["locked"]).to be(true)
      expect(show_body(committed)["locked"]).to be(true)
    end

    it "follows reservation rows on list, not the stored column" do
      get "/v1/companies/#{company_a}/entries", headers: { "Authorization" => "Bearer #{owner_token}" }
      locked_by_id = response.parsed_body["entries"].to_h { |entry| [entry["id"], entry["locked"]] }

      expect(locked_by_id).to eq(unreserved.id => false, provisional.id => true, committed.id => true)
    end
  end

  it "writes nothing when reading" do
    entry = create_reads_spec_entry
    before = Entry.find(entry.id).attributes

    show_body(entry)
    list_ids(owner_token)

    expect(Entry.find(entry.id).attributes).to eq(before)
    expect(Reservation.count).to eq(0)
  end
end
