# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::Identity do
  let(:public_key) { rsa_key_pair.public_key.to_pem }
  let(:service_token) { SecureRandom.hex(32) }

  def resolve(authorization, service_token: self.service_token)
    described_class.resolve(authorization:, public_key:, service_token:)
  end

  it "takes the user, company and role from a verified token" do
    identity = resolve("Bearer #{mint_token({ sub: 42, company_id: 9, role: 'admin' })}")

    expect(identity).to have_attributes(kind: :user, status: :verified, user_id: 42, company_id: 9, role: "admin")
  end

  it "reports a validly signed expired token as expired and anonymous" do
    identity = resolve("Bearer #{mint_token({ exp: Time.now.to_i - 1 })}")

    expect(identity).to have_attributes(kind: :anonymous, status: :expired, company_id: nil)
  end

  it "keeps an expired token's signed company apart from company_id, so logs still read it as unverified" do
    identity = resolve("Bearer #{mint_token({ company_id: 9, exp: Time.now.to_i - 1 })}")

    expect(identity).to have_attributes(status: :expired, company_id: nil, role: nil, signed_company_id: 9)
    expect(Timekeeping::RequestIdentity.company_tag(identity)).to eq("unverified")
  end

  it "gives a verified user's company as the signed company" do
    identity = resolve("Bearer #{mint_token({ company_id: 9 })}")

    expect(identity.signed_company_id).to eq(9)
  end

  it "gives no signed company to a forged expired token or the service" do
    forged = mint_token({ exp: Time.now.to_i - 1 }, key: OpenSSL::PKey::RSA.generate(2048))

    expect(resolve("Bearer #{forged}").signed_company_id).to be_nil
    expect(resolve("Bearer #{service_token}").signed_company_id).to be_nil
  end

  it "reports a forged token as invalid and anonymous" do
    identity = resolve("Bearer #{mint_token({}, key: OpenSSL::PKey::RSA.generate(2048))}")

    expect(identity).to have_attributes(kind: :anonymous, status: :invalid, company_id: nil, role: nil)
  end

  it "reports a missing header as missing" do
    expect(resolve(nil)).to have_attributes(kind: :anonymous, status: :missing)
    expect(resolve("  ")).to have_attributes(kind: :anonymous, status: :missing)
  end

  it "reports a header that is not a bearer token as invalid" do
    expect(resolve("Basic abc")).to have_attributes(kind: :anonymous, status: :invalid)
  end

  it "verifies no token when the public key is missing" do
    identity = described_class.resolve(
      authorization: "Bearer #{mint_token}", public_key: nil, service_token:
    )

    expect(identity).to have_attributes(kind: :anonymous, status: :invalid)
  end

  describe "a signed service token" do
    def service_jwt(key: rsa_key_pair, algorithm: "RS256", **claims)
      now = Time.now.to_i
      JWT.encode({ typ: "timekeeping_service", sub: "invoice-boundary", company_id: 9,
                   operations: ["reservations.prepare"], iat: now, exp: now + 60, jti: SecureRandom.uuid }.merge(claims),
                 key, algorithm)
    end

    it "takes the service name, company and operations from the verified claims" do
      expect(resolve("Bearer #{service_jwt}")).to have_attributes(
        kind: :service, status: :verified, user_id: nil, role: nil, company_id: 9,
        service_name: "invoice-boundary", operations: ["reservations.prepare"]
      )
    end

    it "reports an expired service token as expired and anonymous, with no company" do
      expect(resolve("Bearer #{service_jwt(exp: Time.now.to_i - 1)}"))
        .to have_attributes(kind: :anonymous, status: :expired, company_id: nil, signed_company_id: nil)
    end

    it "reports a service token signed with another key, or with a wrong claim, as invalid" do
      [service_jwt(key: OpenSSL::PKey::RSA.generate(2048)), service_jwt(typ: "user"),
       service_jwt(company_id: "9"), service_jwt(operations: "reservations.prepare")].each do |token|
        expect(resolve("Bearer #{token}")).to have_attributes(kind: :anonymous, status: :invalid)
      end
    end

    # The shared token is sent as a bearer on every reference read, so a
    # token signed with it must bind no company.
    it "refuses a service token signed with the shared service token as an HMAC secret" do
      expect(resolve("Bearer #{service_jwt(key: service_token, algorithm: 'HS256')}"))
        .to have_attributes(kind: :anonymous, status: :invalid)
    end

    it "gives a user token and the raw shared token no operations and no service name" do
      expect(resolve("Bearer #{mint_token({ company_id: 9 })}"))
        .to have_attributes(kind: :user, service_name: nil, operations: [])
      expect(resolve("Bearer #{service_token}"))
        .to have_attributes(kind: :service, company_id: nil, service_name: nil, operations: [])
    end
  end

  describe "the service token" do
    it "gives the service kind for an exact match" do
      expect(resolve("Bearer #{service_token}")).to have_attributes(kind: :service, status: :verified, company_id: nil)
    end

    it "does not match a different value of the same length" do
      expect(resolve("Bearer #{SecureRandom.hex(32)}")).to have_attributes(kind: :anonymous, status: :invalid)
    end

    [nil, ""].each do |unset|
      it "authenticates no one when the configured token is #{unset.inspect}" do
        expect(resolve("Bearer ", service_token: unset)).to have_attributes(kind: :anonymous)
        expect(resolve("Bearer #{service_token}", service_token: unset))
          .to have_attributes(kind: :anonymous, status: :invalid)
      end
    end
  end
end
