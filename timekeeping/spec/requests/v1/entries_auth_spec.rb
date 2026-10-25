# frozen_string_literal: true

require "rails_helper"

# Who may read entries: token refusals answer 401 and every tenant probe
# answers the same 404 as a missing id.
RSpec.describe "Timekeeping entry reads: identity and tenant guard" do
  let(:company_a) { 1 }
  let(:company_b) { 2 }
  let(:not_found_body) { '{"reason":"not_found"}' }
  let(:unauthorized_body) { '{"reason":"unauthorized"}' }

  around do |example|
    with_timekeeping_env(Timekeeping::Environment::TOKEN_PUBLIC_KEY => rsa_key_pair.public_key.to_pem) { example.run }
  end

  def create_auth_spec_entry(company_id:, user_id:, **attributes)
    Entry.create!(
      company_id:, user_id:, project_id: 10, work_date: Date.new(2026, 1, 5),
      duration: 60.0, note: "work", bill_status: "unbilled", **attributes
    )
  end

  def read_entry(company_id, entry_id, token)
    get "/v1/companies/#{company_id}/entries/#{entry_id}", headers: { "Authorization" => "Bearer #{token}" }
    [response.status, response.body, response.media_type]
  end

  def list_entries_for(company_id, token)
    get "/v1/companies/#{company_id}/entries", headers: { "Authorization" => "Bearer #{token}" }
    [response.status, response.body, response.media_type]
  end

  describe "tenant guard" do
    let(:admin_a_token) { mint_token({ sub: 7, company_id: company_a, role: "admin" }) }
    let(:missing_id_response) { read_entry(company_a, 999_999_999, admin_a_token) }

    it "answers a missing id with 404 not_found" do
      expect(missing_id_response).to eq([404, not_found_body, "application/json"])
    end

    it "answers a real entry of another company exactly as a missing id" do
      foreign = create_auth_spec_entry(company_id: company_b, user_id: 7)

      expect(read_entry(company_a, foreign.id, admin_a_token)).to eq(missing_id_response)
    end

    it "answers an admin token for company A on a company B path exactly as a missing id" do
      foreign = create_auth_spec_entry(company_id: company_b, user_id: 7)

      expect(read_entry(company_b, foreign.id, admin_a_token)).to eq(missing_id_response)
      expect(list_entries_for(company_b, admin_a_token)).to eq(missing_id_response)
    end

    it "answers a discarded entry exactly as a missing id" do
      discarded = create_auth_spec_entry(company_id: company_a, user_id: 7, discarded_at: Time.current)

      expect(read_entry(company_a, discarded.id, admin_a_token)).to eq(missing_id_response)
    end

    it "answers an employee reading a colleague's entry exactly as a missing id" do
      colleague_entry = create_auth_spec_entry(company_id: company_a, user_id: 8)
      employee_token = mint_token({ sub: 7, company_id: company_a, role: "employee" })

      expect(read_entry(company_a, colleague_entry.id, employee_token)).to eq(missing_id_response)
    end

    it "answers ids that are not plain integers exactly as a missing id" do
      entry = create_auth_spec_entry(company_id: company_a, user_id: 7)

      expect(read_entry(company_a, "#{entry.id}abc", admin_a_token)).to eq(missing_id_response)
      expect(read_entry(company_a, "9" * 19, admin_a_token)).to eq(missing_id_response)
    end
  end

  describe "token refusals" do
    let(:entry) { create_auth_spec_entry(company_id: company_a, user_id: 7) }

    def expect_unauthorized(token)
      expect(read_entry(company_a, entry.id, token)).to eq([401, unauthorized_body, "application/json"])
    end

    it "refuses an HS256 token signed with the public key's PEM" do
      expect_unauthorized(mint_token({}, key: rsa_key_pair.public_key.to_pem, algorithm: "HS256"))
    end

    it "refuses an alg none token" do
      expect_unauthorized("#{encode_segment({ alg: 'none', typ: 'JWT' })}.#{encode_segment(valid_token_claims)}.")
    end

    it "refuses a token signed by another RSA key" do
      expect_unauthorized(mint_token({}, key: OpenSSL::PKey::RSA.generate(2048)))
    end

    it "refuses a token signed by the attacker key its jwk header carries" do
      attacker_key = OpenSSL::PKey::RSA.generate(2048)
      jwk = JWT::JWK.new(attacker_key.public_key).export

      expect_unauthorized(mint_token({}, key: attacker_key, headers: { jwk: }))
    end

    it "refuses a token missing jti" do
      claims = valid_token_claims.except(:jti)

      expect_unauthorized(JWT.encode(claims, rsa_key_pair, "RS256"))
    end

    it "refuses a validly signed token expired by one second" do
      now = Time.now.to_i

      expect_unauthorized(mint_token({ iat: now - 61, exp: now - 1 }))
    end

    it "refuses a validly signed token whose role is not a string, rather than failing" do
      expect_unauthorized(mint_token({ role: 1 }))
    end

    it "refuses the service token on a user route" do
      with_timekeeping_env(Timekeeping::Environment::SERVICE_TOKEN => "service-#{SecureRandom.hex(16)}") do
        expect_unauthorized(ENV.fetch(Timekeeping::Environment::SERVICE_TOKEN))
      end
    end

    it "refuses a request with no Authorization header" do
      get "/v1/companies/#{company_a}/entries/#{entry.id}"

      expect([response.status, response.body]).to eq([401, unauthorized_body])
    end
  end
end
