# frozen_string_literal: true

# Keys and tokens for Timekeeping identity specs. Every key pair is generated
# when the example runs, so no key is ever written into the tree.
module TokenHelpers
  def rsa_key_pair
    @rsa_key_pair ||= OpenSSL::PKey::RSA.generate(2048)
  end

  # The claims the monolith's Timekeeping::UserToken mints, valid for a minute.
  def valid_token_claims(overrides = {})
    now = Time.now.to_i
    { sub: 7, company_id: 1, role: "employee", iat: now, exp: now + 60, jti: SecureRandom.uuid }.merge(overrides)
  end

  def mint_token(claims = {}, key: rsa_key_pair, algorithm: "RS256", headers: {})
    JWT.encode(valid_token_claims(claims), key, algorithm, headers)
  end

  def encode_segment(hash)
    Base64.urlsafe_encode64(JSON.generate(hash), padding: false)
  end

  # Sets each named variable for the block and puts every previous value back.
  def with_timekeeping_env(values)
    previous = values.keys.index_with { |name| ENV.fetch(name, nil) }
    values.each { |name, value| ENV[name] = value }
    yield
  ensure
    previous&.each { |name, value| ENV[name] = value }
  end
end

RSpec.configure do |config|
  config.include TokenHelpers
end
