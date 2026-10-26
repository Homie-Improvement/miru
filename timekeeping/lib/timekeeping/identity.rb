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
  #
  # purpose is the token's signed purpose claim ("read" or "write"), or nil for
  # a token signed without one. Only WriteAccess reads it: a read token may
  # carry a raised role, so it must never authorize a write.
  #
  # A service caller is either the raw shared TIMEKEEPING_SERVICE_TOKEN, which
  # acts for no company and holds no operations, or a signed service token
  # (Timekeeping::ServiceTokenVerifier), whose verified claims give its
  # service_name, its one company_id and the operations it may run.
  Identity = Data.define(:kind, :status, :user_id, :company_id, :role, :signed_company_id, :purpose,
                         :service_name, :operations) do
    def initialize(signed_company_id: nil, purpose: nil, service_name: nil, operations: [], **fields)
      super(signed_company_id:, purpose:, service_name:, operations: operations.freeze, **fields)
    end

    def self.anonymous(status, signed_company_id: nil)
      new(kind: :anonymous, status:, user_id: nil, company_id: nil, role: nil, signed_company_id:)
    end

    def self.service
      new(kind: :service, status: :verified, user_id: nil, company_id: nil, role: nil)
    end

    def self.bound_service(claims)
      new(
        kind: :service,
        status: :verified,
        user_id: nil,
        company_id: claims.fetch("company_id"),
        role: nil,
        service_name: claims.fetch("sub"),
        operations: claims.fetch("operations")
      )
    end

    def self.user(claims)
      new(
        kind: :user,
        status: :verified,
        user_id: claims.fetch("sub"),
        company_id: claims.fetch("company_id"),
        role: claims.fetch("role"),
        signed_company_id: claims.fetch("company_id"),
        purpose: claims["purpose"]
      )
    end

    BEARER = /\ABearer (\S+)\z/

    # Pure: every input is an argument and nothing is read from ENV. An unset
    # or empty service token matches no caller, and a missing or unreadable
    # public key verifies no user or service token.
    def self.resolve(authorization:, public_key:, service_token:)
      return anonymous(:missing) if authorization.to_s.strip.empty?

      token = bearer(authorization)
      return anonymous(:invalid) unless token
      return service if service_token?(token, service_token)

      signed(token, public_key:)
    rescue TokenVerifier::ExpiredToken => e
      anonymous(:expired, signed_company_id: e.company_id)
    rescue ServiceTokenVerifier::ExpiredToken
      anonymous(:expired)
    rescue TokenVerifier::InvalidToken
      anonymous(:invalid)
    end

    # Both kinds are signed with the same key. A service token must carry
    # typ "timekeeping_service", which no user token has, and a user token
    # needs an integer sub and a role, which no service token has, so neither
    # verifies as the other.
    def self.signed(token, public_key:)
      bound_service(ServiceTokenVerifier.verify(token, public_key:))
    rescue ServiceTokenVerifier::InvalidToken
      user(TokenVerifier.verify(token, public_key:))
    end
    private_class_method :signed

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
