# frozen_string_literal: true

require "openssl"
require "securerandom"

module TimekeepingDemo
  # The signing key pair and service token of one demo run. They are made fresh
  # on every start and live only in the started processes' environments.
  Credentials = Data.define(:private_key_pem, :public_key_pem, :service_token)

  class Credentials
    KEY_BITS = 2048
    TOKEN_BYTES = 32

    def self.generate
      key = OpenSSL::PKey::RSA.generate(KEY_BITS)
      new(private_key_pem: key.to_pem, public_key_pem: key.public_key.to_pem,
          service_token: SecureRandom.hex(TOKEN_BYTES))
    end

    # Keeps the key and token out of logs and error messages.
    def inspect
      "#<#{self.class.name} [hidden]>"
    end
    alias_method :to_s, :inspect
  end
end
