# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::EntryApiClient do
  let(:entry_api_company) { create(:company) }
  let(:entry_api_admin) do
    create(:user).tap do |admin|
      create(:employment, company: entry_api_company, user: admin)
      admin.add_role(:admin, entry_api_company)
    end
  end
  let(:entry_api_base_url) { "http://timekeeping.test" }
  let(:entry_api_list_url) { %r{\Ahttp://timekeeping\.test/v1/companies/#{entry_api_company.id}/entries} }

  def with_entry_api_key(&block)
    with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV, timekeeping_key_pair.to_pem, &block)
  end

  it "reads a user who left the company with a token minted for the acting admin" do
    former = create(:user)
    create(:employment, company: entry_api_company, user: former).discard!
    tokens = []
    stub_request(:get, entry_api_list_url).to_return do |request|
      tokens << request.headers["Authorization"].delete_prefix("Bearer ")
      { status: 200, body: { entries: [{ "id" => 1 }] }.to_json }
    end

    entries = with_entry_api_key do
      described_class.new(base_url: entry_api_base_url).list_entries(
        company_id: entry_api_company.id, user_id: former.id, from: Date.new(2026, 3, 1), to: Date.new(2026, 3, 31),
        acting_user_id: entry_api_admin.id
      )
    end

    expect(entries).to eq([{ "id" => 1 }])
    expect(WebMock).to have_requested(:get, entry_api_list_url).with(query: hash_including("user_id" => former.id.to_s))
    claims = Timekeeping::UserToken.verify(tokens.first, public_key: timekeeping_key_pair.public_key)
    expect(claims.user_id).to eq(entry_api_admin.id)
  end

  it "raises its own error when Timekeeping answers anything but 200 or cannot be reached" do
    [{ status: 500, body: "" }, SocketError, Net::OpenTimeout].each do |answer|
      stub = stub_request(:get, entry_api_list_url)
      answer.is_a?(Hash) ? stub.to_return(answer) : stub.to_raise(answer)

      expect do
        with_entry_api_key do
          described_class.new(base_url: entry_api_base_url).list_entries(
            company_id: entry_api_company.id, user_id: entry_api_admin.id, from: Date.new(2026, 3, 1),
            to: Date.new(2026, 3, 31)
          )
        end
      end.to raise_error(described_class::Error)
    end
  end
end
