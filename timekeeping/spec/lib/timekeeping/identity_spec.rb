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
