# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::CredentialScan do
  let(:public_key) { rsa_key_pair.public_key.to_pem }
  let(:caller_token) { mint_token({ sub: 7, company_id: 1, role: "employee" }) }
  let(:service_token) { "service-secret" }
  let(:held) { [service_token] }

  def found?(body, bearer: caller_token, held: self.held, public_key: self.public_key)
    described_class.found?(body, bearer:, held:, public_key:)
  end

  # Parses wire JSON the way a write does, so escapes are decoded first.
  def parsed(wire_json)
    JSON.parse(wire_json)
  end

  # Replaces the first occurrence of letter in value with its JSON \u escape.
  def escape_letter(value, letter)
    value.sub(letter, format("\\u%04x", letter.ord))
  end

  it "finds the caller's token when a JSON escape replaced one of its letters on the wire" do
    wire = %({"proof_metadata":{"token":"#{escape_letter(caller_token, 'e')}"}})

    expect(wire).not_to include(caller_token)
    expect(found?(parsed(wire))).to be(true)
  end

  it "finds an escaped held service credential" do
    wire = %({"proof_metadata":{"token":"\\u0073ervice-secret"}})

    expect(wire).not_to include(service_token)
    expect(found?(parsed(wire))).to be(true)
  end

  it "finds an escaped user token other than the caller's" do
    other = mint_token({ sub: 9, company_id: 1, role: "admin" })
    wire = %({"source_metadata":{"copied":"#{escape_letter(other, 'e')}"}})

    expect(found?(parsed(wire))).to be(true)
  end

  it "finds a credential used as a nested hash key" do
    expect(found?({ "source_metadata" => { "deep" => { caller_token => "x" } } })).to be(true)
    expect(found?({ "source_metadata" => { service_token => 1 } })).to be(true)
  end

  it "finds the caller's token nested in source_metadata" do
    expect(found?({ "source_metadata" => { "list" => [{ "auth" => caller_token }] } })).to be(true)
  end

  it "finds a service credential behind a Bearer prefix" do
    expect(found?({ "proof_metadata" => { "header" => "Bearer #{service_token}" } })).to be(true)
  end

  it "finds a credential configured in TIMEKEEPING_SERVICE_CREDENTIALS" do
    extra = "svc-#{SecureRandom.hex(8)}"

    with_timekeeping_env(Timekeeping::Environment::SERVICE_CREDENTIALS => "#{SecureRandom.hex(4)},#{extra}") do
      expect(found?({ "note" => "keep #{extra} safe" }, held: Timekeeping.config.service_credentials)).to be(true)
    end
  end

  it "finds a correctly signed token whose exp has passed" do
    expired = mint_token({ sub: 9, exp: Time.now.to_i - 60 })

    expect(found?({ "note" => expired })).to be(true)
  end

  it "finds a user token with base64url text glued to both ends" do
    other = mint_token({ sub: 9 })

    expect(found?({ "note" => "ab.cd#{other}xyz.more" })).to be(true)
  end

  it "does not count a JWT-shaped string with a bad signature" do
    forged = mint_token({ sub: 9 }, key: OpenSSL::PKey::RSA.generate(2048))

    expect(found?({ "note" => forged })).to be(false)
  end

  it "does not refuse a plain entry body" do
    body = {
      "project_id" => 5, "work_date" => "2026-03-02", "duration" => 90.0, "note" => "Design review v1.2.3",
      "source" => "manual", "source_metadata" => { "client" => "web" }, "proof_metadata" => {}
    }

    expect(found?(body)).to be(false)
  end

  it "verifies no token when the public key is missing, but still finds literal credentials" do
    other = mint_token({ sub: 9 })

    expect(found?({ "note" => other }, public_key: nil)).to be(false)
    expect(found?({ "note" => service_token }, public_key: nil)).to be(true)
  end

  it "finds a user token behind a long run of eyJ glued to its header" do
    other = mint_token({ sub: 9 })

    expect(found?({ "note" => ("eyJ" * 70_000) + other })).to be(true)
  end

  it "scans a 200 KB run of eyJ in one segment in bounded time" do
    signature = "s" * 400
    body = { "note" => "#{"eyJ" * 70_000}.payload.#{signature}" }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect(found?(body)).to be(false)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
  end
end
