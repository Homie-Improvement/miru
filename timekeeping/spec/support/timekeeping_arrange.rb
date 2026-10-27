# frozen_string_literal: true

# The timekeeping_arrange the shared contract examples call, for the real
# provider. Entries and reservations are seeded through the models, and the
# admitted generation through Timekeeping::Admission. Users, projects and
# agents live in the monolith, so they are kept in an in-memory catalogue that a WebMock
# stub of the reference endpoint serves.
# Tokens are RS256, signed with a key generated once per run.
class TimekeepingProviderArrange
  REFERENCE_URL = "http://reference.test"
  REFERENCE_HOST = %r{\A#{Regexp.escape(REFERENCE_URL)}(:80)?/}
  REFERENCE_PATH = %r{/internal/v1/companies/(?<company_id>\d+)/reference\z}
  EDIT_DAYS = 30
  TOKEN_LIFETIME = 5.minutes

  def self.signing_key
    @signing_key ||= OpenSSL::PKey::RSA.generate(2048)
  end

  attr_reader :current_generation

  def initialize(signing_key:, service_token:)
    @signing_key = signing_key
    @service_token = service_token
    @last_id = 0
    @users = {}
    @company_users = {}
    @company_projects = {}
    @company_agents = {}
    @service_credentials = []
    @current_generation = 1
  end

  def company
    company_id = next_id
    @company_users[company_id] = []
    @company_projects[company_id] = []
    @company_agents[company_id] = []
    company_id
  end

  def user(company:, role:)
    user_id = next_id
    @users[user_id] = { company_id: company, role: }
    @company_users.fetch(company) << user_id
    user_id
  end

  def token_for(user)
    claims = @users.fetch(user)
    now = Time.now.to_i
    JWT.encode({ sub: user, company_id: claims[:company_id], role: claims[:role], iat: now,
                 exp: now + TOKEN_LIFETIME.to_i, jti: SecureRandom.uuid }, @signing_key, "RS256")
  end

  # A service caller's credential. For a company it is a signed service token
  # bound to that company, listing the operations the examples name by route
  # (prepare, mark_billed, ...) as Timekeeping::ReservationAccess spells them.
  # Without a company it is a held credential. Either way the provider must
  # refuse a body that carries it.
  def service_identity(company:, name:, operations:)
    return held_credential(name) if company.nil?

    now = Time.now.to_i
    granted = operations.map { |operation| Timekeeping::ReservationAccess::ROUTE_OPERATIONS.fetch(operation.to_sym, operation) }
    JWT.encode({ typ: Timekeeping::ServiceTokenVerifier::TYPE, sub: name, company_id: company, operations: granted,
                 iat: now, exp: now + TOKEN_LIFETIME.to_i, jti: SecureRandom.uuid },
               @signing_key, Timekeeping::ServiceTokenVerifier::ALGORITHM)
  end

  def held_credential(name)
    credential = "#{name}-#{SecureRandom.hex(24)}"
    @service_credentials << credential
    ENV[Timekeeping::Environment::SERVICE_CREDENTIALS] = @service_credentials.join(",")
    credential
  end

  def project(company:)
    project_id = next_id
    @company_projects.fetch(company) << project_id
    project_id
  end

  # An agent of the company that belongs to user. Only arranged agents are
  # listed, so the reference stub never vouches for an agent nobody set up.
  def agent(company:, user:)
    agent_id = next_id
    @company_agents.fetch(company) << { id: agent_id, user_id: user }
    agent_id
  end

  def entry(company:, user:, project:, **attributes)
    Entry.create!({
      company_id: company, user_id: user, project_id: project, work_date: "2026-03-02", duration: 90.0,
      note: "Design review", bill_status: "unbilled", source: "manual", source_metadata: {}
    }.merge(attributes)).id
  end

  def reserved_entry(company:, invoice_id:, state: "committed", disposition: "active", **attributes)
    entry_id = entry(company:, user: user(company:, role: "employee"), project: project(company:), **attributes)
    Reservation.create!(company_id: company, entry_id:, invoice_id:, state:, disposition:,
                        operation_id: SecureRandom.uuid, created_at: Time.current)
    entry_id
  end

  # The readers below answer from the database, so the shared examples see
  # exactly what the provider stored. locked comes from the same reservation
  # check the entry API uses.
  def entry_locked(entry_id)
    stored_entry(entry_id).fetch("locked")
  end

  def stored_entry(entry_id)
    Timekeeping::EntryPresenter.call(Entry.select("entries.*", Timekeeping::EntriesQuery::RESERVED).find(entry_id))
  end

  def outbox_size
    OutboxSnapshot.count
  end

  def reservations_for(entry_id)
    Reservation.where(entry_id:).order(:created_at, :invoice_id).pluck(:invoice_id, :state).map do |invoice_id, state|
      { "invoice_id" => invoice_id, "state" => state }
    end
  end

  # Admits writes at the new generation only. The generation is global, so
  # this covers every company, arranged or not.
  def set_generation(generation)
    Timekeeping::Admission.admit!(generation:)
    @current_generation = generation
  end

  # Serves the reference endpoint from the catalogue, answering only the
  # service token, as the monolith does.
  def stub_reference
    WebMock.stub_request(:get, REFERENCE_HOST).to_return do |request|
      path = REFERENCE_PATH.match(request.uri.path)
      next { status: 404, body: JSON.generate(reason: "not_found") } unless path
      next { status: 401, body: JSON.generate(reason: "unauthorized") } unless authorized?(request)

      company_id = Integer(path[:company_id], 10)
      { status: 200, headers: { "Content-Type" => "application/json" },
        body: JSON.generate(reference_facts(company_id, requested_project_ids(request))) }
    end
  end

  private

    def next_id
      @last_id += 1
    end

    def authorized?(request)
      request.headers["Authorization"] == "Bearer #{@service_token}"
    end

    def requested_project_ids(request)
      URI.decode_www_form(request.uri.query.to_s).to_h.fetch("project_ids", "").split(",").map { |id| Integer(id, 10) }
    end

    def reference_facts(company_id, project_ids)
      owned, missing = project_ids.partition { |id| @company_projects.fetch(company_id, []).include?(id) }
      {
        company_id:,
        edit_days: EDIT_DAYS,
        users: @company_users.fetch(company_id, []).map { |id| { id:, role: @users.fetch(id)[:role] } },
        projects: owned.map { |id| { id:, company_id:, billable: true, member_user_ids: [] } },
        missing_project_ids: missing,
        agents: @company_agents.fetch(company_id, [])
      }
    end
end
