# frozen_string_literal: true

require "rails_helper"
require "openssl"

RSpec.describe TimekeepingDemo::Credentials do
  it "generates a fresh matching key pair and service token on every call" do
    # "`bin/timekeeping-demo` generates an ephemeral key pair and a random service token at runtime."
    first = described_class.generate
    second = described_class.generate

    # A second run never reuses the key pair or token of an earlier one.
    expect(first.public_key_pem).not_to eq(second.public_key_pem)
    expect(first.private_key_pem).not_to eq(second.private_key_pem)
    expect(first.service_token).not_to eq(second.service_token)
    expect(first.service_token.length).to be >= 32

    private_key = OpenSSL::PKey::RSA.new(first.private_key_pem)
    expect(private_key.private?).to be(true)
    expect(private_key.public_key.to_pem).to eq(OpenSSL::PKey::RSA.new(first.public_key_pem).to_pem)
    expect(first.public_key_pem).not_to include("PRIVATE KEY")
    expect(OpenSSL::PKey::RSA.new(first.public_key_pem)).not_to be_private
  end
end
