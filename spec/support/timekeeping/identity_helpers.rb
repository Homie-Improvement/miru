# frozen_string_literal: true

# Keys and service tokens for Timekeeping identity specs. Every secret is
# generated when the example runs, so none is ever written into the tree.
module TimekeepingIdentityHelpers
  def timekeeping_key_pair
    @timekeeping_key_pair ||= OpenSSL::PKey::RSA.generate(2048)
  end

  # Takes one name and value, or a Hash of them, and puts every previous value
  # back afterwards.
  def with_timekeeping_env(name_or_values, value = nil, &block)
    values = name_or_values.is_a?(Hash) ? name_or_values : { name_or_values => value }
    previous = values.keys.index_with { |name| ENV.fetch(name, nil) }
    values.each { |name, new_value| ENV[name] = new_value }
    block.call
  ensure
    previous&.each { |name, old_value| ENV[name] = old_value }
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
