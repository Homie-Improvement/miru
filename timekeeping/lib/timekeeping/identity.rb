# frozen_string_literal: true

require "active_support/security_utils"

module Timekeeping
  # Who is calling, worked out from the Authorization header alone. The user,
  # company and role come only from a verified token's sub, company_id and
  # role claims; a role is never read apart from the company in the same token.
  #
  # kind:   :user, :service or :anonymous (the actor kind written to logs)
  # status: :verified, :expired, :invalid or :missing
  Identity = Data.define(:kind, :status, :user_id, :company_id, :role) do
    def self.anonymous(status)
      new(kind: :anonymous, status:, user_id: nil, company_id: nil, role: nil)
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
        role: claims.fetch("role")
      )
    end

    BEARER = /\ABearer (\S+)\z/

    # Pure: every input is an argument and nothing is read from ENV. An unset
    # or empty service token matches no caller, and a missing or unreadable
    # public key verifies no token.
    def self.resolve(authorization:, public_key:, service_token:)
      return anonymous(:missing) if authorization.to_s.strip.empty?

      token = authorization.to_s[BEARER, 1]
      return anonymous(:invalid) unless token
      return service if service_token?(token, service_token)

      user(TokenVerifier.verify(token, public_key:))
    rescue TokenVerifier::ExpiredToken
      anonymous(:expired)
    rescue TokenVerifier::InvalidToken
      anonymous(:invalid)
    end

    def self.service_token?(token, service_token)
      return false if service_token.to_s.empty?

      ActiveSupport::SecurityUtils.secure_compare(token, service_token.to_s)
    end
    private_class_method :service_token?
  end
end
