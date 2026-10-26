# frozen_string_literal: true

module Timekeeping
  # Mints and verifies the short-lived signed token the monolith hands to the
  # Timekeeping service for a user-delegated read or write. The token carries
  # the reference facts Timekeeping decides on (role, edit window, project
  # facts) and its signed purpose, so one token speaks for one user in one
  # company only, and for reads or for writes only.
  #
  # Every call into the jwt gem lives here; callers see only this class and its
  # errors, never a JWT:: exception.
  class UserToken
    ALGORITHM = "RS256"
    TTL = 60.seconds
    PRIVATE_KEY_ENV = "TIMEKEEPING_TOKEN_PRIVATE_KEY"
    REQUIRED_CLAIMS = %w[exp sub company_id role jti].freeze

    # The roles that read every entry of the company, as the entry API
    # contract names them.
    PRIVILEGED_ROLES = YAML.safe_load_file(Rails.root.join("contracts/timekeeping/entry_api.yml"))
      .fetch("privileged_roles").freeze

    # The role each purpose signs, from the user's reference role and the role
    # names they hold in the company, oldest first. A write keeps the reference
    # role, so write authority never changes here. A read takes an owner or
    # admin role the user holds in the company, matching the index
    # authorization (has_role?(:admin, company)) that lets them read colleagues.
    ROLE_FOR_PURPOSE = {
      write: ->(reference_role:, **) { reference_role },
      read: lambda do |reference_role:, held_role_names:|
        held_role_names.find { |name| PRIVILEGED_ROLES.include?(name) } || reference_role
      end
    }.freeze

    class Error < StandardError; end
    class InvalidTokenError < Error; end
    class MissingKeyError < Error; end
    class NotInCompanyError < Error; end
    class AgentMismatchError < Error; end

    # The verified facts of a token. The role is only ever read beside the
    # company it was issued for.
    Claims = Data.define(:user_id, :company_id, :role, :purpose, :edit_days, :projects, :agent_id, :jti, :expires_at)

    # purpose is :write (the default) or :read. A write token's role comes from
    # the same facts the reference endpoint serves, so the two always agree on
    # a user's role in a company. A read token may carry a higher role than
    # the endpoint serves; Timekeeping refuses it on every write route.
    def self.mint(user:, company:, project_ids: [], agent: nil, purpose: :write, private_key: private_key_from_env,
                  now: Time.current)
      role_rule = ROLE_FOR_PURPOSE.fetch(purpose) { raise ArgumentError, "unknown token purpose #{purpose.inspect}" }
      facts = ReferenceFacts.call(company:, project_ids:)
      user_facts = facts[:users].find { |listed| listed[:id] == user.id }
      raise NotInCompanyError, "user is not employed in this company" unless user_facts
      if agent && (agent.company_id != company.id || agent.user_id != user.id)
        raise AgentMismatchError, "agent must belong to the same user and company"
      end

      issued_at = now.to_i
      payload = {
        sub: user.id,
        company_id: company.id,
        role: role_rule.call(reference_role: user_facts[:role], held_role_names: held_role_names(user, company)),
        purpose: purpose.to_s,
        edit_days: facts[:edit_days],
        projects: facts[:projects].map do |project|
          {
            id: project[:id],
            company_id: project[:company_id],
            billable: project[:billable],
            member: project[:member_user_ids].include?(user.id)
          }
        end,
        iat: issued_at,
        exp: issued_at + TTL.to_i,
        jti: SecureRandom.uuid
      }
      payload[:agent_id] = agent.id if agent

      JWT.encode(payload, private_key, ALGORITHM)
    end

    # The algorithm is fixed here and never taken from the token header, so a
    # token signed with "none" or with HMAC over the public key is refused.
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
      claims_from(payload)
    rescue JWT::DecodeError, OpenSSL::PKey::PKeyError
      raise InvalidTokenError, "invalid Timekeeping user token"
    end

    def self.private_key_from_env
      pem = ENV[PRIVATE_KEY_ENV].to_s
      raise MissingKeyError, "#{PRIVATE_KEY_ENV} is not set" if pem.blank?

      key = OpenSSL::PKey::RSA.new(pem)
      raise MissingKeyError, "#{PRIVATE_KEY_ENV} is not an RSA private key" unless key.private?

      key
    rescue OpenSSL::PKey::PKeyError
      raise MissingKeyError, "#{PRIVATE_KEY_ENV} is not an RSA private key"
    end

    # Only roles whose resource is exactly this company count, so a role held
    # in another company or a global role never reaches the token.
    def self.held_role_names(user, company)
      Role.where(resource: company).joins(:users).where(users: { id: user.id }).order("roles.id").pluck("roles.name")
    end
    private_class_method :held_role_names

    def self.rsa_key(key)
      rsa = key.is_a?(OpenSSL::PKey::RSA) ? key : OpenSSL::PKey::RSA.new(key.to_s)
      rsa.public_key
    end
    private_class_method :rsa_key

    def self.claims_from(payload)
      Claims.new(
        user_id: payload.fetch("sub"),
        company_id: payload.fetch("company_id"),
        role: payload.fetch("role"),
        purpose: payload["purpose"],
        edit_days: payload["edit_days"],
        projects: Array(payload["projects"]),
        agent_id: payload["agent_id"],
        jti: payload.fetch("jti"),
        expires_at: Time.zone.at(payload.fetch("exp"))
      )
    end
    private_class_method :claims_from
  end
end
