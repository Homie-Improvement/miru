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
    # The environment key each value travels under: the names the monolith and
    # Timekeeping already read (docs/architecture/timekeeping-soa.md 11.2).
    ENV_KEYS = {
      private_key_pem: "TIMEKEEPING_TOKEN_PRIVATE_KEY",
      public_key_pem: "TIMEKEEPING_TOKEN_PUBLIC_KEY",
      service_token: "TIMEKEEPING_SERVICE_TOKEN"
    }.freeze

    def self.generate
      key = OpenSSL::PKey::RSA.generate(KEY_BITS)
      new(private_key_pem: key.to_pem, public_key_pem: key.public_key.to_pem,
          service_token: SecureRandom.hex(TOKEN_BYTES))
    end

    # Answers the set env holds, or nil unless all three values are present and
    # not blank. A partial set is never adopted, so a caller can never pair a
    # supplied key with a generated one.
    def self.from_env(env)
      values = ENV_KEYS.transform_values { |key| env[key] }
      return nil if values.each_value.any? { |value| value.nil? || value.strip.empty? }

      new(**values)
    end

    # The values under their environment keys, for a Process.spawn env hash.
    def to_env
      ENV_KEYS.to_h { |attribute, key| [key, public_send(attribute)] }
    end

    # Keeps the key and token out of logs and error messages.
    def inspect
      "#<#{self.class.name} [hidden]>"
    end
    alias_method :to_s, :inspect
  end
end
