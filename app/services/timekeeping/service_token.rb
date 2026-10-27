# frozen_string_literal: true

module Timekeeping
  # Mints and verifies the short-lived signed token the monolith hands to the
  # Timekeeping service for a background command, such as detaching a deleted
  # agent's entries. One token speaks for one company and names the
  # operations it may run; Timekeeping grants only the named operations that
  # its background allowlist also holds.
  #
  # It is signed with the same asymmetric key as Timekeeping::UserToken and
  # never with the shared TIMEKEEPING_SERVICE_TOKEN, which works across every
  # company and so must never leave the monolith.
  #
  # Every call into the jwt gem lives here; callers see only this class and its
  # errors, never a JWT:: exception.
  class ServiceToken
    ALGORITHM = UserToken::ALGORITHM
    TTL = UserToken::TTL
    TYPE = "timekeeping_service"
    # The identity Timekeeping records as the caller of a background command.
    SUBJECT = "miru-monolith"
    REQUIRED_CLAIMS = %w[typ sub company_id operations exp jti].freeze

    # The operation name Timekeeping requires on the detach-entries route.
    DETACH_ENTRIES = "agents.detach_entries"

    class InvalidTokenError < UserToken::Error; end

    Claims = Data.define(:subject, :company_id, :operations, :jti, :expires_at)

    # A new token on every call, so a token minted for one company is never
    # reused for another.
    def self.mint(company_id:, operations:, private_key: UserToken.private_key_from_env, now: Time.current)
      issued_at = now.to_i
      payload = {
        typ: TYPE,
        sub: SUBJECT,
        company_id: Integer(company_id),
        operations: Array(operations).map(&:to_s),
        iat: issued_at,
        exp: issued_at + TTL.to_i,
        jti: SecureRandom.uuid
      }

      JWT.encode(payload, private_key, ALGORITHM)
    end

    # The algorithm is fixed here and never taken from the token header, so a
    # token signed with "none" or with HMAC over a shared secret is refused.
    def self.verify(token, public_key:)
      payload, _header = JWT.decode(
        token.to_s,
        rsa_key(public_key),
        true,
        algorithm: ALGORITHM,
        required_claims: REQUIRED_CLAIMS,
        verify_expiration: true,
        leeway: 0
      )
      raise InvalidTokenError, "invalid Timekeeping service token" unless payload["typ"] == TYPE

      claims_from(payload)
    rescue JWT::DecodeError, OpenSSL::PKey::PKeyError
      raise InvalidTokenError, "invalid Timekeeping service token"
    end

    def self.rsa_key(key)
      rsa = key.is_a?(OpenSSL::PKey::RSA) ? key : OpenSSL::PKey::RSA.new(key.to_s)
      rsa.public_key
    end
    private_class_method :rsa_key

    def self.claims_from(payload)
      Claims.new(
        subject: payload.fetch("sub"),
        company_id: payload.fetch("company_id"),
        operations: Array(payload.fetch("operations")),
        jti: payload.fetch("jti"),
        expires_at: Time.zone.at(payload.fetch("exp"))
      )
    end
    private_class_method :claims_from
  end
end
