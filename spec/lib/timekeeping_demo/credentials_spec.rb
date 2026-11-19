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

  it "from_env adopts only a complete, non-blank set and answers nil for any missing or blank key" do
    supplied = described_class.generate
    complete = supplied.to_env

    # "`Credentials.from_env(env)` returns a `Credentials` only when all three values are present and not blank, and nil otherwise."
    # An unrelated key beside a complete set does not stop it being adopted.
    adopted = described_class.from_env(complete.merge("PATH" => "/usr/bin"))
    expect(adopted.is_a?(described_class)).to be(true)
    # Comparisons report booleans, so a failure never prints a key or token.
    expect(adopted.private_key_pem == supplied.private_key_pem).to be(true)
    expect(adopted.public_key_pem == supplied.public_key_pem).to be(true)
    expect(adopted.service_token == supplied.service_token).to be(true)

    described_class::ENV_KEYS.each_value do |key|
      expect(described_class.from_env(complete.except(key)).nil?).to be(true), "expected nil with #{key} missing"
      [nil, "", "   "].each do |blank|
        expect(described_class.from_env(complete.merge(key => blank)).nil?).to be(true),
                                                                               "expected nil with #{key} #{blank.inspect}"
      end
    end
    expect(described_class.from_env({}).nil?).to be(true)
  end

  it "to_env builds the spawn hash with each value under its own key" do
    # "Use the keys the apps already read: `TIMEKEEPING_TOKEN_PRIVATE_KEY`, `TIMEKEEPING_TOKEN_PUBLIC_KEY` and `TIMEKEEPING_SERVICE_TOKEN`."
    expect(described_class::ENV_KEYS.values).to contain_exactly(
      "TIMEKEEPING_TOKEN_PRIVATE_KEY", "TIMEKEEPING_TOKEN_PUBLIC_KEY", "TIMEKEEPING_SERVICE_TOKEN"
    )
    credentials = described_class.generate

    # "`Credentials#to_env` builds the spawn hash."
    env = credentials.to_env
    expect(env.keys).to contain_exactly(*described_class::ENV_KEYS.values)
    expect(env["TIMEKEEPING_TOKEN_PRIVATE_KEY"] == credentials.private_key_pem).to be(true)
    expect(env["TIMEKEEPING_TOKEN_PUBLIC_KEY"] == credentials.public_key_pem).to be(true)
    expect(env["TIMEKEEPING_SERVICE_TOKEN"] == credentials.service_token).to be(true)

    # The round trip gives back the same set, and the same spawn hash.
    adopted = described_class.from_env(env)
    expect(adopted == credentials).to be(true)
    expect(adopted.to_env == env).to be(true)
  end

  it "inspect and to_s hide every credential value" do
    credentials = described_class.generate

    shown = [credentials.inspect, credentials.to_s].join
    credentials.to_env.each do |key, value|
      expect(shown.include?(value)).to be(false), "expected #{key} to be hidden"
    end
  end
end
