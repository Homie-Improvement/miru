# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::UserToken do
  let(:company_a) { create(:company, timesheet_edit_days: 7) }
  let(:company_b) { create(:company, timesheet_edit_days: 30) }
  let(:project_a) { create(:project, client: create(:client, company: company_a), billable: true) }
  let(:project_b) { create(:project, client: create(:client, company: company_b), billable: false) }
  let(:user) { create(:user) }
  let(:private_key) { timekeeping_key_pair }
  let(:public_key) { timekeeping_key_pair.public_key }

  before do
    create(:employment, company: company_a, user:)
    create(:employment, company: company_b, user:)
    user.add_role(:admin, company_a)
    user.add_role(:employee, company_b)
    create(:project_member, project: project_a, user:)
  end

  def mint(**options)
    described_class.mint(user:, company: company_a, private_key:, **options)
  end

  def segments(token)
    token.split(".")
  end

  def encode_segment(hash)
    Base64.urlsafe_encode64(JSON.generate(hash), padding: false)
  end

  def valid_payload(overrides = {})
    now = Time.current.to_i
    { sub: user.id, company_id: company_a.id, role: "admin", iat: now, exp: now + 60, jti: SecureRandom.uuid }
      .merge(overrides)
  end

  describe ".verify refusals" do
    it "refuses an unsigned token with alg none" do
      header = encode_segment({ alg: "none", typ: "JWT" })
      token = "#{header}.#{encode_segment(valid_payload)}."

      expect { described_class.verify(token, public_key:) }
        .to raise_error(described_class::InvalidTokenError)
    end

    it "refuses an HS256 token signed with the public key's PEM text" do
      token = JWT.encode(valid_payload, public_key.to_pem, "HS256")

      expect { described_class.verify(token, public_key:) }
        .to raise_error(described_class::InvalidTokenError)
      expect { described_class.verify(token, public_key: public_key.to_pem) }
        .to raise_error(described_class::InvalidTokenError)
    end

    it "refuses a token signed by another key pair" do
      token = JWT.encode(valid_payload, OpenSSL::PKey::RSA.generate(2048), "RS256")

      expect { described_class.verify(token, public_key:) }
        .to raise_error(described_class::InvalidTokenError)
    end

    it "refuses a validly signed token whose payload was changed" do
      header, _payload, signature = segments(mint)
      forged = [header, encode_segment(valid_payload(role: "owner")), signature].join(".")

      expect { described_class.verify(forged, public_key:) }
        .to raise_error(described_class::InvalidTokenError)
    end

    it "refuses an expired token" do
      token = mint

      travel 61.seconds do
        expect { described_class.verify(token, public_key:) }
          .to raise_error(described_class::InvalidTokenError)
      end
    end

    %i[exp company_id role sub jti].each do |claim|
      it "refuses a signed token without #{claim}" do
        token = JWT.encode(valid_payload.except(claim), private_key, "RS256")

        expect { described_class.verify(token, public_key:) }
          .to raise_error(described_class::InvalidTokenError)
      end
    end

    it "raises only its own error, and the message holds no token text" do
      token = JWT.encode(valid_payload, OpenSSL::PKey::RSA.generate(2048), "RS256")

      expect { described_class.verify(token, public_key:) }.to raise_error do |error|
        expect(error).to be_a(described_class::InvalidTokenError)
        expect(error.class.name).not_to start_with("JWT::")
        token.split(".").each { |segment| expect(error.message).not_to include(segment) }
      end
    end
  end

  describe ".mint" do
    it "round-trips the reference claims for one company" do
      claims = described_class.verify(mint(project_ids: [project_a.id]), public_key:)

      expect(claims.user_id).to eq(user.id)
      expect(claims.company_id).to eq(company_a.id)
      expect(claims.role).to eq("admin")
      expect(claims.edit_days).to eq(7)
      expect(claims.projects).to eq(
        [{ "id" => project_a.id, "company_id" => company_a.id, "billable" => true, "member" => true }]
      )
      expect(claims.agent_id).to be_nil
    end

    it "expires 60 seconds after it is issued and gets a fresh jti each time" do
      freeze_time do
        first = JWT.decode(mint, public_key, true, algorithm: "RS256").first
        second = JWT.decode(mint, public_key, true, algorithm: "RS256").first

        expect(first["exp"] - first["iat"]).to eq(60)
        expect(first["iat"]).to eq(Time.current.to_i)
        expect(first["jti"]).not_to eq(second["jti"])
      end
    end

    it "carries each company's own role for a user in two companies" do
      token_b = described_class.mint(user:, company: company_b, private_key:)
      claims_a = described_class.verify(mint, public_key:)
      claims_b = described_class.verify(token_b, public_key:)

      expect([claims_a.company_id, claims_a.role]).to eq([company_a.id, "admin"])
      expect([claims_b.company_id, claims_b.role]).to eq([company_b.id, "employee"])
    end

    it "leaves another company's project out of the projects claim" do
      claims = described_class.verify(mint(project_ids: [project_a.id, project_b.id]), public_key:)

      expect(claims.projects.pluck("id")).to eq([project_a.id])
    end

    it "refuses a user without an employment in the company" do
      outsider = create(:user)

      expect { described_class.mint(user: outsider, company: company_a, private_key:) }
        .to raise_error(described_class::NotInCompanyError)
    end

    it "refuses an agent that belongs to another user of the same company" do
      other_agent = create(:agent, company: company_a)

      expect { mint(agent: other_agent) }.to raise_error(described_class::AgentMismatchError)
    end

    it "refuses the user's own agent from another company" do
      agent_in_b = create(:agent, company: company_b, user:)

      expect { mint(agent: agent_in_b) }.to raise_error(described_class::AgentMismatchError)
    end

    it "marks an in-company project the user has not joined as member false" do
      colleague = create(:user)
      create(:employment, company: company_a, user: colleague)
      other_project = create(:project, client: project_a.client, billable: false)
      create(:project_member, project: other_project, user: colleague)

      claims = described_class.verify(mint(project_ids: [project_a.id, other_project.id]), public_key:)

      expect(claims.projects).to contain_exactly(
        { "id" => project_a.id, "company_id" => company_a.id, "billable" => true, "member" => true },
        { "id" => other_project.id, "company_id" => company_a.id, "billable" => false, "member" => false }
      )
    end

    it "adds agent_id for the user's own agent" do
      agent = create(:agent, company: company_a, user:)

      expect(described_class.verify(mint(agent:), public_key:).agent_id).to eq(agent.id)
    end

    it "signs with TIMEKEEPING_TOKEN_PRIVATE_KEY by default" do
      with_timekeeping_env(described_class::PRIVATE_KEY_ENV, private_key.to_pem) do
        token = described_class.mint(user:, company: company_a)

        expect(described_class.verify(token, public_key:).company_id).to eq(company_a.id)
      end
    end

    it "refuses to mint without a key and never echoes the key" do
      with_timekeeping_env(described_class::PRIVATE_KEY_ENV, nil) do
        expect { described_class.mint(user:, company: company_a) }
          .to raise_error(described_class::MissingKeyError, /TIMEKEEPING_TOKEN_PRIVATE_KEY/)
      end

      garbage = "not-a-key-#{SecureRandom.hex(8)}"
      with_timekeeping_env(described_class::PRIVATE_KEY_ENV, garbage) do
        expect { described_class.mint(user:, company: company_a) }.to raise_error do |error|
          expect(error).to be_a(described_class::MissingKeyError)
          expect(error.message).not_to include(garbage)
        end
      end
    end

    it "refuses a public key in place of the private key" do
      with_timekeeping_env(described_class::PRIVATE_KEY_ENV, public_key.to_pem) do
        expect { described_class.mint(user:, company: company_a) }
          .to raise_error(described_class::MissingKeyError)
      end
    end
  end
end

# Generated by Descant: acceptance tests below.
RSpec.describe Timekeeping::UserToken, "write role agrees with reference facts" do
  # "A write token for a user who holds employee first and admin or owner later in a company signs the admin or owner role with purpose write"
  # "ReferenceFacts serves the same role for that user, so token and reference endpoint agree"
  # "Roles held in another company or globally never raise the signed role"
  # Each row asserts the expected role as a literal as well as the agreement,
  # because the token reads its role from ReferenceFacts and a shared mistake
  # would otherwise still agree. Every example gets fresh companies, so one
  # row's roles rows never decide another row's role order.
  let(:scoped_company) { create(:company) }
  let(:elsewhere_company) { create(:company) }

  def scoped_member(*roles)
    create(:user).tap do |member|
      create(:employment, company: scoped_company, user: member)
      roles.each { |role| member.add_role(role, scoped_company) }
    end
  end

  def elsewhere_member(*scoped_roles, elsewhere_role:)
    scoped_member(*scoped_roles).tap do |member|
      create(:employment, company: elsewhere_company, user: member)
      member.add_role(elsewhere_role, elsewhere_company)
    end
  end

  [
    { case: "an employee-first admin", role: "admin", member: -> { scoped_member(:employee, :admin) } },
    { case: "an employee-first owner", role: "owner", member: -> { scoped_member(:employee, :owner) } },
    { case: "an employee who later holds admin and then owner", role: "admin",
      member: -> { scoped_member(:employee, :admin, :owner) } },
    { case: "a manager only", role: "manager", primary_role: "manager", member: -> { scoped_member(:manager) } },
    { case: "a plain employee", role: "employee", member: -> { scoped_member(:employee) } },
    { case: "a roleless member", role: "employee", member: -> { scoped_member } },
    { case: "a global admin", role: "employee",
      member: -> { scoped_member(:employee).tap { |member| member.add_role(:admin) } } },
    { case: "another company's admin", role: "employee",
      member: -> { elsewhere_member(:employee, elsewhere_role: :admin) } },
    { case: "another company's owner", role: "employee", member: -> { elsewhere_member(elsewhere_role: :owner) } }
  ].each do |row|
    it "signs #{row[:role]} on the write token of #{row[:case]}, and the reference facts serve the same role" do
      member = instance_exec(&row[:member])
      primary_role = row.fetch(:primary_role, "employee")

      token = described_class.mint(user: member, company: scoped_company, private_key: timekeeping_key_pair)
      claims = described_class.verify(token, public_key: timekeeping_key_pair.public_key)
      served_role = Timekeeping::ReferenceFacts.call(company: scoped_company, project_ids: [])[:users]
        .find { |listed| listed[:id] == member.id }&.fetch(:role)

      expect([claims.user_id, claims.company_id, claims.role, claims.purpose, claims.primary_role])
        .to eq([member.id, scoped_company.id, row[:role], "write", primary_role])
      expect(served_role).to eq(row[:role])
      expect(User.primary_roles_for(scoped_company, [member.id])).to eq(member.id => primary_role)
    end
  end
end

RSpec.describe Timekeeping::UserToken, "purpose stays a separate claim" do
  # "A read token must still never be accepted for writes. Purpose stays a separate claim."
  it "keeps read and write tokens apart by their signed purpose once both carry the raised role of an employee-first admin" do
    company = create(:company)
    member = create(:user)
    create(:employment, company:, user: member)
    member.add_role(:employee, company)
    member.add_role(:admin, company)

    signed = %i[read write].map do |purpose|
      token = described_class.mint(user: member, company:, private_key: timekeeping_key_pair, purpose:)
      claims = described_class.verify(token, public_key: timekeeping_key_pair.public_key)
      [claims.role, claims.purpose, claims.primary_role]
    end

    expect(signed).to eq([%w[admin read employee], %w[admin write employee]])
    [:admin, "read", "write"].each do |unsupported|
      expect { described_class.mint(user: member, company:, private_key: timekeeping_key_pair, purpose: unsupported) }
        .to raise_error(ArgumentError)
    end
  end
end

RSpec.describe Timekeeping::UserToken, "write role per company" do
  let(:admin_company) { create(:company) }
  let(:employee_company) { create(:company) }

  # "Roles held in another company, and global roles, must still never reach the token."
  # The admin role in admin_company is newer than the employee role there, so
  # only the privileged-first rule signs admin; it must not leak to employee_company.
  it "signs each company's own role on the write token of a user employed in two companies" do
    member = create(:user)
    create(:employment, company: admin_company, user: member)
    create(:employment, company: employee_company, user: member)
    member.add_role(:employee, admin_company)
    member.add_role(:employee, employee_company)
    member.add_role(:admin, admin_company)

    signed = [admin_company, employee_company].map do |company|
      token = described_class.mint(user: member, company:, private_key: timekeeping_key_pair)
      claims = described_class.verify(token, public_key: timekeeping_key_pair.public_key)
      [claims.company_id, claims.role, claims.purpose]
    end

    expect(signed).to eq([[admin_company.id, "admin", "write"], [employee_company.id, "employee", "write"]])
  end
end

RSpec.describe Timekeeping::UserToken, "write role across companies" do
  # "Roles held in another company or globally never raise the signed role"
  it "keeps employee on a write token for a user employed in two companies who is admin only in the other one" do
    this_company = create(:company)
    other_company = create(:company)
    member = create(:user)
    create(:employment, company: this_company, user: member)
    create(:employment, company: other_company, user: member)
    member.add_role(:employee, this_company)
    member.add_role(:admin, other_company)
    member.add_role(:owner)

    token = described_class.mint(user: member, company: this_company, private_key: timekeeping_key_pair)
    claims = described_class.verify(token, public_key: timekeeping_key_pair.public_key)
    other_token = described_class.mint(user: member, company: other_company, private_key: timekeeping_key_pair)
    other_claims = described_class.verify(other_token, public_key: timekeeping_key_pair.public_key)

    expect([claims.company_id, claims.role, claims.primary_role, claims.purpose])
      .to eq([this_company.id, "employee", "employee", "write"])
    expect([other_claims.company_id, other_claims.role, other_claims.purpose])
      .to eq([other_company.id, "admin", "write"])
  end
end

RSpec.describe Timekeeping::UserToken, "write role order" do
  # "Make the write purpose sign the owner or admin role the user holds in that company, using the same
  # rule the read purpose already uses (`held_role_names` filtered by `PRIVILEGED_ROLES`)."
  # The read rule takes the first privileged name in roles.id order, so admin (added before owner) wins.
  it "signs the oldest privileged role and the lowest-id primary role when an employee later holds admin and then owner" do
    company = create(:company)
    member = create(:user)
    create(:employment, company:, user: member)
    member.add_role(:employee, company)
    member.add_role(:admin, company)
    member.add_role(:owner, company)

    signed = %i[write read].map do |purpose|
      token = described_class.mint(user: member, company:, purpose:, private_key: timekeeping_key_pair)
      claims = described_class.verify(token, public_key: timekeeping_key_pair.public_key)
      [claims.role, claims.primary_role, claims.purpose]
    end

    expect(signed).to eq([%w[admin employee write], %w[admin employee read]])
  end
end
