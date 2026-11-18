# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimekeepingDemo::Credentials do
  # "`bin/timekeeping-demo` generates an ephemeral key pair and a random service token at runtime."
  it "generates a fresh matching key pair and service token on every call" do
    first = described_class.generate
    second = described_class.generate

    expect(first.public_key_pem).not_to eq(second.public_key_pem)
    expect(first.private_key_pem).not_to eq(second.private_key_pem)
    expect(first.service_token).not_to eq(second.service_token)
    expect(first.service_token.length).to be >= 32

    private_key = OpenSSL::PKey::RSA.new(first.private_key_pem)
    expect(private_key.public_key.to_pem).to eq(OpenSSL::PKey::RSA.new(first.public_key_pem).to_pem)
  end
end
