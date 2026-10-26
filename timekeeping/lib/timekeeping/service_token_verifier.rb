# frozen_string_literal: true

module Timekeeping
  # Verifies the signed service token a background caller sends with each
  # request: an RS256 token signed with the monolith's token key that binds the
  # call to one company and to the operations it names. The key is the one
  # TIMEKEEPING_TOKEN_PUBLIC_KEY verifies, never a value any caller sends as a
  # bearer, so holding the shared TIMEKEEPING_SERVICE_TOKEN does not let anyone
  # mint a token for another company. Every call into the jwt gem for these
  # tokens lives here; callers see only this module's two errors, and neither
  # error message holds any part of the token.
  module ServiceTokenVerifier
    # Fixed here and never read from the token header, so a token signed with
    # "none" or with HMAC over the public key's PEM text is refused.
    ALGORITHM = "RS256"
    # User tokens carry no typ claim, so one never verifies as a service token.
    TYPE = "timekeeping_service"
    REQUIRED_CLAIMS = %w[typ sub company_id operations exp jti].freeze

    # The company and operations come only from these claims, so a token whose
    # claims have another shape grants nothing.
    CLAIM_RULES = {
      "typ" => ->(value) { value == TYPE },
      "sub" => ->(value) { value.is_a?(String) && !value.empty? },
      "company_id" => ->(value) { value.is_a?(Integer) },
      "operations" => ->(value) { value.is_a?(Array) && value.all?(String) }
    }.freeze

    class InvalidToken < StandardError; end

    # Raised only after the signature verified, so a forged token is never
    # reported as expired.
    class ExpiredToken < StandardError; end

    module_function

    # The key is passed in, never looked up from the token's header. A missing
    # or unreadable key verifies nothing. The jwt gem checks the signature
    # before exp, so a forged token that has also expired raises InvalidToken.
    def verify(token, public_key:)
      payload = decode(token, public_key, verify_expiration: true)
      raise InvalidToken, "invalid Timekeeping service token" unless valid_claims?(payload)

      payload
    rescue JWT::ExpiredSignature
      raise ExpiredToken, "expired Timekeeping service token" if expired_service_token?(token, public_key)

      raise InvalidToken, "invalid Timekeeping service token"
    rescue JWT::DecodeError, OpenSSL::PKey::PKeyError
      raise InvalidToken, "invalid Timekeeping service token"
    end

    def decode(token, public_key, verify_expiration:)
      payload, _header = JWT.decode(
        token.to_s, rsa_public_key(public_key), true,
        algorithm: ALGORITHM, required_claims: REQUIRED_CLAIMS, verify_expiration:, leeway: 0
      )
      payload
    end

    # Reached only after the signature verified and exp had passed. An
    # expired user token, signed with the same key, is not a service token,
    # so it is left for the user token verifier to report.
    def expired_service_token?(token, public_key)
      valid_claims?(decode(token, public_key, verify_expiration: false))
    rescue JWT::DecodeError
      false
    end

    def rsa_public_key(key)
      rsa = key.is_a?(OpenSSL::PKey::RSA) ? key : OpenSSL::PKey::RSA.new(key.to_s)
      rsa.public_key
    end

    def valid_claims?(payload)
      CLAIM_RULES.all? { |claim, valid| valid.call(payload[claim]) }
    end

    private_class_method :decode, :expired_service_token?, :rsa_public_key, :valid_claims?
  end
end
