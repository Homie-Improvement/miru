# frozen_string_literal: true

# Keys and service tokens for Timekeeping identity specs. Every secret is
# generated when the example runs, so none is ever written into the tree.
module TimekeepingIdentityHelpers
  def timekeeping_key_pair
    @timekeeping_key_pair ||= OpenSSL::PKey::RSA.generate(2048)
  end

  def with_timekeeping_env(name, value)
    previous = ENV.fetch(name, nil)
    ENV[name] = value
    yield
  ensure
    ENV[name] = previous
  end

  # Sets a random service token for the duration of the block and yields it.
  def with_timekeeping_service_token(&block)
    token = SecureRandom.hex(32)
    with_timekeeping_env(Internal::V1::BaseController::SERVICE_TOKEN_ENV, token) { block.call(token) }
  end
end

RSpec.configure do |config|
  config.include TimekeepingIdentityHelpers
end
