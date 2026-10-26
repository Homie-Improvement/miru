# frozen_string_literal: true

RSpec.describe TimekeepingRules::CredentialScan, "signed tokens" do
  let(:key_pair) { OpenSSL::PKey::RSA.new(2048) }

  # Unpadded base64url, as a JWT writes each segment. The base64 gem is not a
  # default gem on this Ruby, so this uses Array#pack.
  def base64url(bytes)
    [bytes].pack("m0").tr("+/", "-_").delete("=")
  end

  def signed_token(key)
    header = base64url('{"alg":"RS256"}')
    payload = base64url('{"sub":7}')
    signature = key.sign("SHA256", "#{header}.#{payload}")
    "#{header}.#{payload}.#{base64url(signature)}"
  end

  it "finds a token signed by the held key, given the public half as a key or as PEM" do
    body = { "proof_metadata" => { "a" => { "b" => "copied #{signed_token(key_pair)} here" } } }

    expect(described_class.found?(body, held_token: nil, public_key: key_pair.public_key)).to be(true)
    expect(described_class.found?(body, held_token: nil, public_key: key_pair.public_key.to_pem)).to be(true)
  end

  it "ignores a token signed by another key" do
    body = { "note" => signed_token(OpenSSL::PKey::RSA.new(2048)) }

    expect(described_class.found?(body, held_token: nil, public_key: key_pair.public_key)).to be(false)
  end

  it "skips the signature check without raising when no public key is held" do
    body = { "note" => signed_token(key_pair) }

    expect(described_class.found?(body, held_token: nil, public_key: nil)).to be(false)
    expect(described_class.found?(body, held_token: nil, public_key: "")).to be(false)
  end
end
