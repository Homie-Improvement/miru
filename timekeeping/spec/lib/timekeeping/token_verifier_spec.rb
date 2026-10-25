# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::TokenVerifier do
  let(:public_key) { rsa_key_pair.public_key }
  let(:attacker_key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:expired_one_second_ago) { { exp: Time.now.to_i - 1 } }

  def verify(token, key: public_key)
    described_class.verify(token, public_key: key)
  end

  describe "order of checks" do
    it "reports a token signed by another key as invalid even when it has also expired" do
      token = mint_token(expired_one_second_ago, key: attacker_key)

      expect { verify(token) }.to raise_error(described_class::InvalidToken)
    end

    it "reports a validly signed token expired one second ago as expired" do
      token = mint_token(expired_one_second_ago)

      expect { verify(token) }.to raise_error(described_class::ExpiredToken)
    end
  end

  describe "the company of an expired token" do
    it "carries the signed company_id of a validly signed expired token" do
      token = mint_token(expired_one_second_ago.merge(company_id: 9))

      expect { verify(token) }.to raise_error(described_class::ExpiredToken) { |error| expect(error.company_id).to eq(9) }
    end

    it "carries no company when the expired token's claims have the wrong types" do
      token = mint_token(expired_one_second_ago.merge(company_id: "9"))

      expect { verify(token) }.to raise_error(described_class::ExpiredToken) { |error| expect(error.company_id).to be_nil }
    end
  end

  describe "refusals" do
    it "refuses an HS256 token signed with the public key's PEM text" do
      token = mint_token({}, key: public_key.to_pem, algorithm: "HS256")

      expect { verify(token) }.to raise_error(described_class::InvalidToken)
      expect { verify(token, key: public_key.to_pem) }.to raise_error(described_class::InvalidToken)
    end

    it "refuses an unsigned token with alg none" do
      token = "#{encode_segment({ alg: 'none', typ: 'JWT' })}.#{encode_segment(valid_token_claims)}."

      expect { verify(token) }.to raise_error(described_class::InvalidToken)
    end

    it "refuses a token signed by another RSA key" do
      expect { verify(mint_token({}, key: attacker_key)) }.to raise_error(described_class::InvalidToken)
    end

    it "refuses a token signed by an attacker key that its jwk header carries" do
      jwk = JWT::JWK.new(attacker_key.public_key).export
      token = mint_token({}, key: attacker_key, headers: { jwk: })

      expect { verify(token) }.to raise_error(described_class::InvalidToken)
    end

    it "refuses a validly signed token whose payload was changed" do
      header, _payload, signature = mint_token.split(".")
      forged = [header, encode_segment(valid_token_claims(role: "owner")), signature].join(".")

      expect { verify(forged) }.to raise_error(described_class::InvalidToken)
    end

    %i[exp sub company_id role jti].each do |claim|
      it "refuses a signed token without #{claim}" do
        token = JWT.encode(valid_token_claims.except(claim), rsa_key_pair, "RS256")

        expect { verify(token) }.to raise_error(described_class::InvalidToken)
      end
    end

    {
      "role given as a number" => { role: 1 },
      "sub given as a string" => { sub: "7" },
      "company_id given as a string" => { company_id: "1" }
    }.each do |description, claims|
      it "refuses a signed token with #{description}" do
        expect { verify(mint_token(claims)) }.to raise_error(described_class::InvalidToken)
      end
    end

    [nil, "", "not a key"].each do |key|
      it "refuses every token when the public key is #{key.inspect}" do
        expect { verify(mint_token, key:) }.to raise_error(described_class::InvalidToken)
      end
    end

    it "raises only its own errors, and their messages hold no token text" do
      [mint_token({}, key: attacker_key), mint_token(expired_one_second_ago)].each do |token|
        expect { verify(token) }.to raise_error do |error|
          expect(error.class.module_parent).to eq(described_class)
          token.split(".").each { |segment| expect(error.message).not_to include(segment) }
        end
      end
    end
  end

  describe "a valid token" do
    it "returns the claims with Integer sub and company_id and a String role" do
      claims = verify(mint_token({ sub: 42, company_id: 9, role: "owner" }))

      expect(claims).to include("sub" => 42, "company_id" => 9, "role" => "owner")
      expect(claims.keys).to include("exp", "jti")
    end

    it "accepts the public key as PEM text" do
      expect(verify(mint_token, key: public_key.to_pem)).to include("sub" => 7)
    end
  end
end
