# frozen_string_literal: true

module Timekeeping
  # Verifies the signed service token a background caller sends with each
  # request: an HS256 token signed with TIMEKEEPING_SERVICE_TOKEN that binds
  # the call to one company and to the operations it names. Every call into
  # the jwt gem for these tokens lives here; callers see only this module's two
  # errors, and neither error message holds any part of the token.
  module ServiceTokenVerifier
    # Fixed here and never read from the token header, so a token signed with
    # "none", or an RS256 user token, is refused.
    ALGORITHM = "HS256"
    TYPE = "timekeeping_service"
    REQUIRED_CLAIMS = %w[typ sub company_id operations exp jti].freeze

    # Timekeeping::CredentialScan finds a service token in a body by trying
    # header starts within this many characters before the payload. A longer
    # header is refused here, so every token that verifies is one the scan
    # finds.
    MAX_HEADER_LENGTH = 256

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

    # An empty secret verifies nothing, so an unset TIMEKEEPING_SERVICE_TOKEN
    # admits no caller. The jwt gem checks the signature before exp, so a
    # forged token that has also expired raises InvalidToken.
    def verify(token, secret:)
      raise InvalidToken, "invalid Timekeeping service token" if secret.to_s.empty? || header_too_long?(token)

      payload = decode(token, secret)
      raise InvalidToken, "invalid Timekeeping service token" unless valid_claims?(payload)

      payload
    rescue JWT::ExpiredSignature
      raise ExpiredToken, "expired Timekeeping service token"
    rescue JWT::DecodeError
      raise InvalidToken, "invalid Timekeeping service token"
    end

    def decode(token, secret)
      payload, _header = JWT.decode(
        token.to_s, secret.to_s, true,
        algorithm: ALGORITHM, required_claims: REQUIRED_CLAIMS, verify_expiration: true, leeway: 0
      )
      payload
    end

    def header_too_long?(token)
      token.to_s.split(".", 2).first.to_s.length > MAX_HEADER_LENGTH
    end

    def valid_claims?(payload)
      CLAIM_RULES.all? { |claim, valid| valid.call(payload[claim]) }
    end

    private_class_method :decode, :header_too_long?, :valid_claims?
  end
end
