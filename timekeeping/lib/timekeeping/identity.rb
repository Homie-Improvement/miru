# frozen_string_literal: true

require "active_support/security_utils"

module Timekeeping
  # Who is calling, worked out from the Authorization header alone. The user,
  # company and role come only from a verified token's sub, company_id and
  # role claims; a role is never read apart from the company in the same token.
  #
  # kind:   :user, :service or :anonymous (the actor kind written to logs)
  # status: :verified, :expired, :invalid or :missing
  #
  # signed_company_id is the company_id claim of a token whose signature
  # verified, expired or not. Only write metrics read it, so an expired token
  # is counted under its own company; access decisions and log tags read
  # company_id, which stays nil for an expired token.
  Identity = Data.define(:kind, :status, :user_id, :company_id, :role, :signed_company_id) do
    def initialize(signed_company_id: nil, **fields)
      super
    end

    def self.anonymous(status, signed_company_id: nil)
      new(kind: :anonymous, status:, user_id: nil, company_id: nil, role: nil, signed_company_id:)
    end

    def self.service
      new(kind: :service, status: :verified, user_id: nil, company_id: nil, role: nil)
    end

    def self.user(claims)
      new(
        kind: :user,
        status: :verified,
        user_id: claims.fetch("sub"),
        company_id: claims.fetch("company_id"),
        role: claims.fetch("role"),
        signed_company_id: claims.fetch("company_id")
      )
    end

    BEARER = /\ABearer (\S+)\z/

    # Pure: every input is an argument and nothing is read from ENV. An unset
    # or empty service token matches no caller, and a missing or unreadable
    # public key verifies no token.
    def self.resolve(authorization:, public_key:, service_token:)
      return anonymous(:missing) if authorization.to_s.strip.empty?

      token = bearer(authorization)
      return anonymous(:invalid) unless token
      return service if service_token?(token, service_token)

      user(TokenVerifier.verify(token, public_key:))
    rescue TokenVerifier::ExpiredToken => e
      anonymous(:expired, signed_company_id: e.company_id)
    rescue TokenVerifier::InvalidToken
      anonymous(:invalid)
    end

    # The token of a "Bearer <token>" Authorization header, or nil. Entry
    # writes also read it, to refuse a body that carries the caller's token.
    def self.bearer(authorization)
      authorization.to_s[BEARER, 1]
    end

    # Also used by Timekeeping::LogSafety, so a value equal to the service
    # token is never logged in clear.
    def self.service_token?(token, service_token)
      return false if service_token.to_s.empty?

      ActiveSupport::SecurityUtils.secure_compare(token.to_s, service_token.to_s)
    end
  end
end
