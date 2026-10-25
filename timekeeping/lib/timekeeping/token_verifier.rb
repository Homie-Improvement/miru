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

    # The only form a token may take: three unpadded base64url segments, the
    # first a compact JSON header ('{"' encodes to eyJ) of bounded length, as
    # the monolith mints them. Timekeeping::CredentialScan finds every string
    # of this form inside a write body, so a token this verifier would accept
    # can never pass that scan in another spelling.
    SEGMENT = /\A[A-Za-z0-9_-]+\z/
    SEGMENT_COUNT = 3
    HEADER_START = "eyJ"
    MAX_HEADER_LENGTH = 512

    class InvalidToken < StandardError; end

    # Raised only after the signature verified, so a forged token is never
    # reported as expired. Writes answer it differently from InvalidToken.
    class ExpiredToken < StandardError; end

    module_function

    # The key is passed in, never looked up from the token's kid, jku, jwk or
    # x5u header. The jwt gem checks the signature before exp, so a forged
    # token that has also expired raises InvalidToken.
    def verify(token, public_key:)
      raise InvalidToken, "invalid Timekeeping user token" unless compact?(token.to_s)

      payload, _header = JWT.decode(
        token.to_s,
        rsa_public_key(public_key),
        true,
        algorithm: ALGORITHM,
        required_claims: REQUIRED_CLAIMS,
        verify_expiration: true,
        leeway: 0
      )
      raise InvalidToken, "invalid Timekeeping user token" unless typed_claims?(payload)

      payload
    rescue JWT::ExpiredSignature
      raise ExpiredToken, "expired Timekeeping user token"
    rescue JWT::DecodeError, OpenSSL::PKey::PKeyError
      raise InvalidToken, "invalid Timekeeping user token"
    end

    # Accepts a key object or PEM text; nil, empty or non-RSA text raises
    # OpenSSL::PKey::PKeyError, which verify reports as InvalidToken.
    def rsa_public_key(key)
      rsa = key.is_a?(OpenSSL::PKey::RSA) ? key : OpenSSL::PKey::RSA.new(key.to_s)
      rsa.public_key
    end

    def typed_claims?(payload)
      CLAIM_TYPES.all? { |claim, type| payload[claim].is_a?(type) }
    end

    def compact?(token)
      segments = token.split(".", -1)
      header = segments.first.to_s
      segments.length == SEGMENT_COUNT && segments.all?(SEGMENT) &&
        header.start_with?(HEADER_START) && header.length <= MAX_HEADER_LENGTH
    end

    private_class_method :rsa_public_key, :typed_claims?, :compact?
  end
end
