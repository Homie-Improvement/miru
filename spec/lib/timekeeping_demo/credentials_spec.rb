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

RSpec.describe TimekeepingDemo::Credentials, ".from_env" do
  it "from_env adopts only a complete, non-blank set and answers nil for any missing or blank key" do
    supplied = described_class.generate
    complete = supplied.to_env

    # "`Credentials.from_env(env)` returns a `Credentials` only when all three values are present and not blank, and nil otherwise."
    adopted = described_class.from_env(complete.merge("PATH" => "/usr/bin"))
    expect(adopted.nil?).to be(false)
    expect(adopted.private_key_pem == supplied.private_key_pem).to be(true)
    expect(adopted.public_key_pem == supplied.public_key_pem).to be(true)
    expect(adopted.service_token == supplied.service_token).to be(true)

    described_class::ENV_KEYS.each_value do |key|
      expect(described_class.from_env(complete.except(key)).nil?).to be(true)
      expect(described_class.from_env(complete.merge(key => "")).nil?).to be(true)
      expect(described_class.from_env(complete.merge(key => "   ")).nil?).to be(true)
      expect(described_class.from_env(complete.merge(key => nil)).nil?).to be(true)
    end
  end

  it "to_env holds exactly the three keys the apps read and inspect hides every value" do
    credentials = described_class.generate
    env = credentials.to_env

    # "Use the keys the apps already read: `TIMEKEEPING_TOKEN_PRIVATE_KEY`, `TIMEKEEPING_TOKEN_PUBLIC_KEY` and `TIMEKEEPING_SERVICE_TOKEN`."
    expect(env.keys).to contain_exactly(*described_class::ENV_KEYS.values)
    expect(described_class::ENV_KEYS.values).to contain_exactly(
      *%w[TIMEKEEPING_TOKEN_PRIVATE_KEY TIMEKEEPING_TOKEN_PUBLIC_KEY TIMEKEEPING_SERVICE_TOKEN]
    )

    shown = [credentials.inspect, credentials.to_s].join
    env.each_value { |value| expect(shown.include?(value)).to be(false) }
  end
end

RSpec.describe TimekeepingDemo::Credentials do
  it "from_env adopts a complete set of the three credential keys and ENV_KEYS names exactly those keys" do
    # "Use the keys the apps already read: `TIMEKEEPING_TOKEN_PRIVATE_KEY`, `TIMEKEEPING_TOKEN_PUBLIC_KEY` and `TIMEKEEPING_SERVICE_TOKEN`."
    expected_keys = %w[TIMEKEEPING_TOKEN_PRIVATE_KEY TIMEKEEPING_TOKEN_PUBLIC_KEY TIMEKEEPING_SERVICE_TOKEN]
    expect(described_class::ENV_KEYS.values).to match_array(expected_keys)

    supplied = described_class.generate
    env = {
      "TIMEKEEPING_TOKEN_PRIVATE_KEY" => supplied.private_key_pem,
      "TIMEKEEPING_TOKEN_PUBLIC_KEY" => supplied.public_key_pem,
      "TIMEKEEPING_SERVICE_TOKEN" => supplied.service_token,
      "PATH" => ENV.fetch("PATH")
    }

    # "`Credentials.from_env(env)` returns a `Credentials` only when all three values are present and not blank, and nil otherwise."
    adopted = described_class.from_env(env)
    expect(adopted.is_a?(described_class)).to be(true)
    # Comparisons report booleans, so a failure never prints a key or token.
    expect(adopted.private_key_pem == supplied.private_key_pem).to be(true)
    expect(adopted.public_key_pem == supplied.public_key_pem).to be(true)
    expect(adopted.service_token == supplied.service_token).to be(true)
  end
end

RSpec.describe TimekeepingDemo::Credentials do
  it "from_env answers nil when any one credential key is missing, empty or whitespace only" do
    supplied = described_class.generate
    complete = {
      "TIMEKEEPING_TOKEN_PRIVATE_KEY" => supplied.private_key_pem,
      "TIMEKEEPING_TOKEN_PUBLIC_KEY" => supplied.public_key_pem,
      "TIMEKEEPING_SERVICE_TOKEN" => supplied.service_token
    }

    # "`Credentials.from_env(env)` returns a `Credentials` only when all three values are present and not blank, and nil otherwise."
    complete.each_key do |key|
      missing = complete.except(key)
      expect(described_class.from_env(missing).nil?).to be(true), "expected nil with #{key} missing"

      ["", "   "].each do |blank|
        blanked = complete.merge(key => blank)
        expect(described_class.from_env(blanked).nil?).to be(true), "expected nil with #{key} blank"
      end
    end
    expect(described_class.from_env({}).nil?).to be(true)
  end
end

RSpec.describe TimekeepingDemo::Credentials do
  it "to_env builds the spawn hash with each value under its own key" do
    credentials = described_class.generate

    # "`Credentials#to_env` builds the spawn hash."
    env = credentials.to_env
    expect(env.keys).to match_array(described_class::ENV_KEYS.values)
    expect(env["TIMEKEEPING_TOKEN_PRIVATE_KEY"] == credentials.private_key_pem).to be(true)
    expect(env["TIMEKEEPING_TOKEN_PUBLIC_KEY"] == credentials.public_key_pem).to be(true)
    expect(env["TIMEKEEPING_SERVICE_TOKEN"] == credentials.service_token).to be(true)

    # The round trip gives back the same set.
    round_trip = described_class.from_env(env)
    expect(round_trip == credentials).to be(true)
  end
end

RSpec.describe TimekeepingDemo::Credentials do
  it "from_env answers nil when any one credential is missing, empty or whitespace-only" do
    supplied = described_class.generate.to_env
    keys = described_class::ENV_KEYS.values

    # "`Credentials.from_env(env)` returns a `Credentials` only when all three values are present and not blank, and nil otherwise."
    keys.each do |key|
      [nil, "", "   "].each do |broken|
        env = supplied.dup
        broken.nil? ? env.delete(key) : env[key] = broken
        expect(described_class.from_env(env).nil?).to be(true), "expected nil with #{key} #{broken.inspect}"
      end
    end

    adopted = described_class.from_env(supplied)
    expect(adopted.nil?).to be(false)
    expect(adopted.to_env == supplied).to be(true)
  end
end
