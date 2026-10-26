# frozen_string_literal: true

module Timekeeping
  # Verifies the signed user token the monolith mints with
  # Timekeeping::UserToken (app/services/timekeeping/user_token.rb) and returns
  # its claims. Every call into the jwt gem lives here; callers see only this
  # module's two errors, never a JWT:: or OpenSSL exception, and neither error
  # message holds any part of the token.
  module TokenVerifier
    # Fixed here and never read from the token header, so a token signed with
    # "none" or with HMAC over the public key's PEM text is refused.
    ALGORITHM = "RS256"
    REQUIRED_CLAIMS = %w[exp sub company_id role jti].freeze

    # Downstream rules (TimekeepingRules::EntryRules.visible_scope) raise on
    # other types, so a signed token with a wrongly typed claim is refused here
    # instead of failing later as a server error.
    CLAIM_TYPES = { "sub" => Integer, "company_id" => Integer, "role" => String }.freeze

    # Claims a token may leave out, but must type correctly when it carries
    # them. A purpose of the wrong type is refused here, so it can never be
    # read as a token signed without a purpose, which may write. A
    # primary_role of the wrong type is refused for the same reason: read as
    # absent, it would fall back to the token's role, which may be raised.
    OPTIONAL_CLAIM_TYPES = { "purpose" => String, "primary_role" => String }.freeze

    class InvalidToken < StandardError; end

    # Raised only after the signature verified, so a forged token is never
    # reported as expired. Writes answer it differently from InvalidToken.
    #
    # company_id is the signed company_id claim, or nil when the claims fail
    # CLAIM_TYPES. It lets write metrics count the refusal under the company
    # that signed token names; it grants no access.
    class ExpiredToken < StandardError
      attr_reader :company_id

      def initialize(message = "expired Timekeeping user token", company_id: nil)
        super(message)
        @company_id = company_id
      end
    end

    module_function

    # The key is passed in, never looked up from the token's kid, jku, jwk or
    # x5u header. The jwt gem checks the signature before exp, so a forged
    # token that has also expired raises InvalidToken.
    def verify(token, public_key:)
      payload = decode(token, public_key, verify_expiration: true)
      raise InvalidToken, "invalid Timekeeping user token" unless typed_claims?(payload)

      payload
    rescue JWT::ExpiredSignature
      raise ExpiredToken.new(company_id: expired_company_id(token, public_key))
    rescue JWT::DecodeError, OpenSSL::PKey::PKeyError
      raise InvalidToken, "invalid Timekeeping user token"
    end

    def decode(token, public_key, verify_expiration:)
      payload, _header = JWT.decode(
        token.to_s,
        rsa_public_key(public_key),
        true,
        algorithm: ALGORITHM,
        required_claims: REQUIRED_CLAIMS,
        verify_expiration:,
        leeway: 0
      )
      payload
    end

    # Reached only after the jwt gem verified the signature and then found exp
    # in the past, so decoding again without the exp check reads claims the
    # monolith signed.
    def expired_company_id(token, public_key)
      payload = decode(token, public_key, verify_expiration: false)
      payload["company_id"] if typed_claims?(payload)
    rescue JWT::DecodeError, OpenSSL::PKey::PKeyError
      nil
    end

    # Accepts a key object or PEM text; nil, empty or non-RSA text raises
    # OpenSSL::PKey::PKeyError, which verify reports as InvalidToken.
    def rsa_public_key(key)
      rsa = key.is_a?(OpenSSL::PKey::RSA) ? key : OpenSSL::PKey::RSA.new(key.to_s)
      rsa.public_key
    end

    def typed_claims?(payload)
      CLAIM_TYPES.all? { |claim, type| payload[claim].is_a?(type) } &&
        OPTIONAL_CLAIM_TYPES.all? { |claim, type| !payload.key?(claim) || payload[claim].is_a?(type) }
    end

    private_class_method :decode, :expired_company_id, :rsa_public_key, :typed_claims?
  end
end
