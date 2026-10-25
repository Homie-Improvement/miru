# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::RequestIdentity do
  let(:public_key_pem) { rsa_key_pair.public_key.to_pem }
  let(:seen_env) { {} }
  let(:stub_app) do
    lambda do |env|
      seen_env.merge!(env)
      [200, {}, ["ok"]]
    end
  end

  def get_with(authorization)
    with_timekeeping_env(Timekeeping::Environment::TOKEN_PUBLIC_KEY => public_key_pem) do
      Rack::MockRequest.new(described_class.new(stub_app)).get("/v1/companies/2/entries", "HTTP_AUTHORIZATION" => authorization)
    end
    described_class.from(seen_env)
  end

  def tags_for(env)
    request = ActionDispatch::Request.new(env)
    described_class::LOG_TAGS.map { |tag| tag.call(request) }
  end

  it "stores the verified company and actor for a valid token" do
    identity = get_with("Bearer #{mint_token({ company_id: 1 })}")

    expect(identity).to have_attributes(kind: :user, status: :verified, company_id: 1)
  end

  it "stores an unverified anonymous identity for a forged token" do
    identity = get_with("Bearer #{mint_token({ company_id: 2 }, key: OpenSSL::PKey::RSA.generate(2048))}")

    expect(identity).to have_attributes(kind: :anonymous, status: :invalid, company_id: nil)
  end

  it "tags a verified request with the token's company, a UUID request id and the user actor" do
    get_with("Bearer #{mint_token({ company_id: 1 })}")
    request_id = SecureRandom.uuid

    expect(tags_for(seen_env.merge("action_dispatch.request_id" => request_id)))
      .to eq(["company_id=1", "request_id=#{request_id}", "actor=user"])
  end

  it "tags a forged request as unverified, never with the path's company" do
    get_with("Bearer #{mint_token({ company_id: 2 }, key: OpenSSL::PKey::RSA.generate(2048))}")

    expect(tags_for(seen_env)).to include("company_id=unverified", "actor=anonymous")
  end

  it "tags a verified service caller as having no company, not as unverified" do
    service_token = SecureRandom.hex(32)
    with_timekeeping_env(Timekeeping::Environment::SERVICE_TOKEN => service_token) do
      get_with("Bearer #{service_token}")
    end

    expect(tags_for(seen_env)).to include("company_id=none", "actor=service")
  end

  it "runs before the request logger so its start and end lines carry the tags" do
    stack = Rails.application.middleware.map(&:klass)

    expect(stack.index(described_class)).to be < stack.index(Rails::Rack::Logger)
  end
end
