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
RSpec.describe Timekeeping::UserToken, "read and write purposes" do
  let(:purpose_company) { create(:company) }

  def purpose_member
    create(:user).tap { |member| create(:employment, company: purpose_company, user: member) }
  end

  def purpose_claims(member, **options)
    token = described_class.mint(user: member, company: purpose_company, private_key: timekeeping_key_pair, **options)
    described_class.verify(token, public_key: timekeeping_key_pair.public_key)
  end

  # The employee role is added first, so it has the lower roles.id and sorts
  # first: the primary role stays employee while the read role is raised.
  it "signs a read token with the privileged role an employee-first admin or owner holds in the company" do
    { admin: "admin", owner: "owner" }.each do |privileged, expected_role|
      member = purpose_member
      member.add_role(:employee, purpose_company)
      member.add_role(privileged, purpose_company)

      claims = purpose_claims(member, purpose: :read)

      expect([claims.user_id, claims.company_id, claims.role, claims.purpose])
        .to eq([member.id, purpose_company.id, expected_role, "read"])
    end
  end

  # Write tokens keep the role the reference endpoint serves, so the raised
  # read role never reaches writes.
  it "keeps the lowest-id role and a write purpose on the default token of an employee-first admin or owner" do
    %i[admin owner].each do |privileged|
      member = purpose_member
      member.add_role(:employee, purpose_company)
      member.add_role(privileged, purpose_company)

      claims = purpose_claims(member)
      reference_role = Timekeeping::ReferenceFacts.call(company: purpose_company, project_ids: [])[:users]
        .find { |listed| listed[:id] == member.id }[:role]

      expect(reference_role).to eq("employee")
      expect([claims.role, claims.purpose]).to eq([reference_role, "write"])
      expect(User.primary_roles_for(purpose_company, [member.id])).to eq(member.id => "employee")
    end
  end

  # Only an owner or admin role whose resource is exactly the token's company
  # may raise the read role; a global role, another company's role or no role
  # at all must not.
  it "keeps the employee role on a read token for a global admin, another company's admin and a roleless member" do
    elsewhere = create(:company)
    global_admin = purpose_member
    global_admin.add_role(:employee, purpose_company)
    global_admin.add_role(:admin)
    other_company_admin = purpose_member
    create(:employment, company: elsewhere, user: other_company_admin)
    other_company_admin.add_role(:employee, purpose_company)
    other_company_admin.add_role(:admin, elsewhere)
    both_elsewhere_and_global = purpose_member
    create(:employment, company: elsewhere, user: both_elsewhere_and_global)
    both_elsewhere_and_global.add_role(:employee, purpose_company)
    both_elsewhere_and_global.add_role(:admin, elsewhere)
    both_elsewhere_and_global.add_role(:admin)
    roleless = purpose_member

    signed = [global_admin, other_company_admin, both_elsewhere_and_global, roleless].map do |member|
      claims = purpose_claims(member, purpose: :read)
      [claims.company_id, claims.role, claims.purpose]
    end

    expect(signed).to eq([[purpose_company.id, "employee", "read"]] * 4)
  end

  # An unexpected purpose must never fall back to the privileged read role.
  it "refuses an unknown purpose rather than minting a token with a raised role" do
    member = purpose_member
    member.add_role(:employee, purpose_company)
    member.add_role(:admin, purpose_company)

    expect { purpose_claims(member, purpose: :admin) }.to raise_error(ArgumentError)
    expect { purpose_claims(member, purpose: "read") }.to raise_error(ArgumentError)
  end
end
