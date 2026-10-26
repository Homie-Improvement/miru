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
require "rails_helper"

RSpec.describe Timekeeping::UserToken do
  # Only an owner or admin role held in the token's own company may widen the
  # read; a role from another company or a global role must not.
  it "signs a read token as employee when the only admin roles are global or in another company" do
    home_company = create(:company)
    other_company = create(:company)
    user = create(:user)
    create(:employment, company: home_company, user:)
    create(:employment, company: other_company, user:)
    user.add_role(:employee, home_company)
    user.add_role(:admin, other_company)
    user.add_role(:admin)

    token = described_class.mint(user:, company: home_company, purpose: :read, private_key: timekeeping_key_pair)
    claims = described_class.verify(token, public_key: timekeeping_key_pair.public_key)

    expect([claims.company_id, claims.role, claims.purpose]).to eq([home_company.id, "employee", "read"])
  end
end

require "rails_helper"

RSpec.describe Timekeeping::UserToken do
  # "That rule also drives billed and locked checks and the reference endpoint; changing it is an identity decision."
  # Write tokens therefore keep the primary role and are signed as write tokens.
  it "keeps the lowest-id employee role and a write purpose on the default token of an employee-first admin" do
    company = create(:company)
    user = create(:user)
    create(:employment, company:, user:)
    user.add_role(:employee, company)
    user.add_role(:admin, company)

    claims = described_class.verify(
      described_class.mint(user:, company:, private_key: timekeeping_key_pair),
      public_key: timekeeping_key_pair.public_key
    )

    expect([claims.role, claims.purpose]).to eq(["employee", "write"])
  end
end

require "rails_helper"

RSpec.describe Timekeeping::UserToken do
  # "Does an admin with an older `employee` role retain access to a colleague's entries?"
  it "signs a read token with the privileged role an employee-first admin or owner holds in the company" do
    company = create(:company)
    { admin: "admin", owner: "owner" }.each do |privileged, expected_role|
      user = create(:user)
      create(:employment, company:, user:)
      user.add_role(:employee, company)
      user.add_role(privileged, company)

      token = described_class.mint(user:, company:, purpose: :read, private_key: timekeeping_key_pair)
      claims = described_class.verify(token, public_key: timekeeping_key_pair.public_key)

      expect([claims.company_id, claims.role, claims.purpose]).to eq([company.id, expected_role, "read"])
    end
  end
end

require "rails_helper"

RSpec.describe Timekeeping::UserToken do
  # An unexpected purpose must never fall back to the privileged read role.
  it "refuses an unknown mint purpose instead of signing a privileged token" do
    company = create(:company)
    user = create(:user)
    create(:employment, company:, user:)
    user.add_role(:employee, company)
    user.add_role(:admin, company)

    read_claims = described_class.verify(
      described_class.mint(user:, company:, purpose: :read, private_key: timekeeping_key_pair),
      public_key: timekeeping_key_pair.public_key
    )
    expect(read_claims.purpose).to eq("read")

    expect { described_class.mint(user:, company:, purpose: :admin, private_key: timekeeping_key_pair) }
      .to raise_error(ArgumentError)
  end
end

require "rails_helper"

RSpec.describe Timekeeping::UserToken do
  it "signs a read token with the employee role in a company where the user is admin only in another company" do
    reading_company = create(:company)
    other_company = create(:company)
    cross_company_user = create(:user)
    create(:employment, company: reading_company, user: cross_company_user)
    create(:employment, company: other_company, user: cross_company_user)
    cross_company_user.add_role(:admin, other_company)
    cross_company_user.add_role(:employee, reading_company)

    token = described_class.mint(user: cross_company_user, company: reading_company, purpose: :read,
                                 private_key: timekeeping_key_pair)
    claims = described_class.verify(token, public_key: timekeeping_key_pair.public_key)

    # A role held in another company must never widen the read in this one.
    expect(claims.company_id).to eq(reading_company.id)
    expect(claims.role).to eq("employee")
    expect(claims.purpose).to eq("read")
  end
end

require "rails_helper"

RSpec.describe Timekeeping::UserToken do
  it "does not count a global admin role with no company when choosing the read role" do
    reading_company = create(:company)
    global_admin_user = create(:user)
    create(:employment, company: reading_company, user: global_admin_user)
    global_admin_user.add_role(:employee, reading_company)
    global_admin_user.add_role(:admin)

    token = described_class.mint(user: global_admin_user, company: reading_company, purpose: :read,
                                 private_key: timekeeping_key_pair)
    claims = described_class.verify(token, public_key: timekeeping_key_pair.public_key)

    # Only owner or admin roles whose resource is exactly the token's company count.
    expect(claims.role).to eq("employee")
  end
end

require "rails_helper"

RSpec.describe Timekeeping::UserToken, "read and write purposes" do
  it "raises the privileged role only on a read token and keeps the lowest-id role on a write token" do
    # "That rule also drives billed and locked checks and the reference endpoint; changing it is an identity decision."
    company = create(:company)
    public_key = timekeeping_key_pair.public_key
    multi_role = create(:user)
    create(:employment, company:, user: multi_role)
    multi_role.add_role(:employee, company)
    multi_role.add_role(:owner, company)

    read_token = described_class.mint(user: multi_role, company:, private_key: timekeeping_key_pair, purpose: :read)
    write_token = described_class.mint(user: multi_role, company:, private_key: timekeeping_key_pair)
    read_claims = described_class.verify(read_token, public_key:)
    write_claims = described_class.verify(write_token, public_key:)
    reference_role = Timekeeping::ReferenceFacts.call(company:, project_ids: [])[:users]
      .find { |listed| listed[:id] == multi_role.id }[:role]

    expect([read_claims.role, read_claims.purpose]).to eq(["owner", "read"])
    expect([write_claims.role, write_claims.purpose]).to eq(["employee", "write"])
    expect(reference_role).to eq("employee")
  end
end

require "rails_helper"

RSpec.describe Timekeeping::UserToken, "read role boundaries" do
  it "never counts a global role or a missing role as privileged on a read token, and refuses an unknown purpose" do
    company = create(:company)
    global_admin = create(:user)
    create(:employment, company:, user: global_admin)
    global_admin.add_role(:admin)
    global_admin.add_role(:employee, company)
    roleless = create(:user)
    create(:employment, company:, user: roleless)

    roles = [global_admin, roleless].map do |member|
      token = described_class.mint(user: member, company:, private_key: timekeeping_key_pair, purpose: :read)
      described_class.verify(token, public_key: timekeeping_key_pair.public_key).role
    end

    expect(roles).to eq(["employee", "employee"])
    expect { described_class.mint(user: roleless, company:, private_key: timekeeping_key_pair, purpose: :admin) }
      .to raise_error(ArgumentError)
  end
end

require "rails_helper"

# Only an owner or admin role whose resource is exactly the token's company may
# raise the read role; a global role or another company's role must not.
RSpec.describe Timekeeping::UserToken, "read role sources" do
  it "does not raise the read role for an admin role held globally or in another company" do
    home = create(:company)
    elsewhere = create(:company)
    global_admin = create(:user)
    create(:employment, company: home, user: global_admin)
    global_admin.add_role(:employee, home)
    global_admin.add_role(:admin)
    other_company_admin = create(:user)
    create(:employment, company: home, user: other_company_admin)
    create(:employment, company: elsewhere, user: other_company_admin)
    other_company_admin.add_role(:employee, home)
    other_company_admin.add_role(:admin, elsewhere)

    [global_admin, other_company_admin].each do |user|
      token = described_class.mint(user:, company: home, purpose: :read, private_key: timekeeping_key_pair)
      claims = described_class.verify(token, public_key: timekeeping_key_pair.public_key)

      expect([claims.company_id, claims.role]).to eq([home.id, "employee"])
    end
  end
end

require "rails_helper"

RSpec.describe Timekeeping::UserToken, "unknown purpose" do
  it "refuses an unknown purpose rather than minting a token with a raised role" do
    company = create(:company)
    user = create(:user)
    create(:employment, company:, user:)
    user.add_role(:employee, company)
    user.add_role(:admin, company)

    expect { described_class.mint(user:, company:, purpose: :admin, private_key: timekeeping_key_pair) }
      .to raise_error(ArgumentError)
    expect { described_class.mint(user:, company:, purpose: "read", private_key: timekeeping_key_pair) }
      .to raise_error(ArgumentError)
  end
end

RSpec.describe Timekeeping::UserToken do
  # "That rule also drives billed and locked checks and the reference endpoint; changing it is an identity decision."
  # A write token must keep the role the reference endpoint serves, so raising the read role cannot leak into writes.
  it "keeps the lowest-id employee role on a default write token for an employee-first admin while the read token is raised" do
    company = create(:company)
    user = create(:user)
    create(:employment, company:, user:)
    user.add_role(:employee, company)
    user.add_role(:admin, company)

    write_claims = described_class.verify(
      described_class.mint(user:, company:, private_key: timekeeping_key_pair), public_key: timekeeping_key_pair.public_key
    )
    read_claims = described_class.verify(
      described_class.mint(user:, company:, purpose: :read, private_key: timekeeping_key_pair),
      public_key: timekeeping_key_pair.public_key
    )
    reference_role = Timekeeping::ReferenceFacts.call(company:, project_ids: [])[:users].find { |listed| listed[:id] == user.id }[:role]

    expect(reference_role).to eq("employee")
    expect([write_claims.role, write_claims.purpose]).to eq([reference_role, "write"])
    expect([read_claims.role, read_claims.purpose]).to eq(["admin", "read"])
    expect(User.primary_roles_for(company, [user.id])).to eq(user.id => "employee")
  end
end
