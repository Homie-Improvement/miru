# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"

module Timekeeping
  # Reads the facts an entry write is decided on (edit_days, the company's
  # users and agents, and the requested projects) from the monolith's
  # reference endpoint, whose shape is contracts/timekeeping/reference.yml. Every call makes a
  # fresh request: there is no cache, so a write never acts on an older copy.
  # Any failure to read the facts raises Unavailable, so callers refuse the
  # write rather than guess.
  class ReferenceClient
    class Unavailable < StandardError; end

    User = Data.define(:id, :role)
    Project = Data.define(:id, :company_id, :billable, :member_user_ids)
    Agent = Data.define(:id, :user_id)
    Invoice = Data.define(:id, :company_id)
    # owned_agent_ids and invoices are nil when the monolith did not send
    # them, which an older monolith does not. Entry writes never read them,
    # so they keep working beside such a monolith; owned_agent_ids and
    # owned_invoice_ids below refuse instead.
    Facts = Data.define(:company_id, :edit_days, :users, :projects, :missing_project_ids, :agents,
                        :owned_agent_ids, :invoices) do
      def initialize(owned_agent_ids: nil, invoices: nil, **fields)
        super(owned_agent_ids:, invoices:, **fields)
      end

      def user_ids
        users.map(&:id)
      end

      # Each of the company's agent ids mapped to the user it belongs to.
      def agent_owners
        agents.to_h { |agent| [agent.id, agent.user_id] }
      end
    end

    TIMEOUT_SECONDS = 2
    # A slow or broken monolith must not hold up a write, and a transport
    # failure is a reason to refuse it, never to retry or fall back.
    TRANSPORT_ERRORS = [Timeout::Error, SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError,
                        Net::HTTPBadResponse, Net::ProtocolError].freeze

    # The client the service uses: the host and credential come only from the
    # process environment, never from a request.
    def self.configured
      new(base_url: Environment.monolith_reference_url, service_token: Environment.service_token)
    end

    attr_reader :open_timeout, :read_timeout

    def initialize(base_url:, service_token:, open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS)
      @base_url = base_url
      @service_token = service_token
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    # Callers pass ids they have already checked as Integers; anything else is
    # a programming error, because it would be written into the request URL.
    def fetch(company_id:, project_ids:)
      raise ArgumentError, "company_id must be an Integer" unless company_id.is_a?(Integer)
      raise ArgumentError, "project_ids must be Integers" unless project_ids.all?(Integer)

      read_facts(company_id, project_ids:)
    end

    # The requested agent ids that are agents of the company, counting one
    # whose deletion holds its row lock. A response without owned_agent_ids
    # raises Unavailable: reading it as "owns none" would let a detach of the
    # company's own agent skip the marker that refuses later writes naming it.
    def owned_agent_ids(company_id:, agent_ids:)
      raise ArgumentError, "company_id must be an Integer" unless company_id.is_a?(Integer)
      raise ArgumentError, "agent_ids must be Integers" unless agent_ids.all?(Integer)

      owned = read_facts(company_id, project_ids: [], agent_ids:).owned_agent_ids
      raise Unavailable, "reference response lacks owned_agent_ids" if owned.nil?

      owned
    end

    # The requested invoice ids the monolith lists as the company's, counting
    # a new invoice whose save has not committed yet. A response without
    # invoices raises Unavailable: reading it as "owns none" would refuse the
    # company's own invoice, and reading it as "owns all" would let one
    # company write against another's.
    def owned_invoice_ids(company_id:, invoice_ids:)
      raise ArgumentError, "company_id must be an Integer" unless company_id.is_a?(Integer)
      raise ArgumentError, "invoice_ids must be Integers" unless invoice_ids.all?(Integer)

      invoices = read_facts(company_id, project_ids: [], invoice_ids:).invoices
      raise Unavailable, "reference response lacks invoices" if invoices.nil?

      invoices.map(&:id)
    end

    private

      attr_reader :base_url, :service_token

      def read_facts(company_id, project_ids:, agent_ids: [], invoice_ids: [])
        response = get(reference_uri(company_id, project_ids, agent_ids, invoice_ids))
        raise Unavailable, "reference endpoint answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        parse(response.body, company_id)
      end

      # agent_ids and invoice_ids are sent only when asked for, so an entry
      # write's request stays exactly as it was.
      def reference_uri(company_id, project_ids, agent_ids, invoice_ids)
        raise Unavailable, "MONOLITH_REFERENCE_URL is not set" if base_url.to_s.strip.empty?

        uri = URI.parse("#{base_url.chomp("/")}/internal/v1/companies/#{company_id}/reference")
        raise Unavailable, "MONOLITH_REFERENCE_URL is not an http(s) URL" unless uri.is_a?(URI::HTTP) && uri.host

        query = { project_ids: project_ids.join(",") }
        query[:agent_ids] = agent_ids.join(",") if agent_ids.any?
        query[:invoice_ids] = invoice_ids.join(",") if invoice_ids.any?
        uri.query = URI.encode_www_form(query)
        uri
      rescue URI::InvalidURIError
        raise Unavailable, "MONOLITH_REFERENCE_URL is not a valid URL"
      end

      def get(uri)
        raise Unavailable, "TIMEKEEPING_SERVICE_TOKEN is not set" if service_token.to_s.empty?

        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = "Bearer #{service_token}"
        request["Accept"] = "application/json"
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                            open_timeout:, read_timeout:) { |http| http.request(request) }
      rescue *TRANSPORT_ERRORS => e
        raise Unavailable, "reference endpoint unreachable (#{e.class})"
      end

      # A body that is not JSON, or lacks any field reference.yml lists, or
      # carries facts for another company, cannot be trusted to decide a write.
      def parse(body, company_id)
        facts = JSON.parse(body.to_s)
        raise Unavailable, "reference response is malformed" unless valid_facts?(facts, company_id)

        Facts.new(
          company_id: facts["company_id"],
          edit_days: facts["edit_days"],
          users: facts["users"].map { |user| User.new(id: user["id"], role: user["role"]) },
          projects: facts["projects"].map do |project|
            Project.new(id: project["id"], company_id: project["company_id"], billable: project["billable"],
                        member_user_ids: project["member_user_ids"])
          end,
          missing_project_ids: facts["missing_project_ids"],
          agents: facts["agents"].map { |agent| Agent.new(id: agent["id"], user_id: agent["user_id"]) },
          owned_agent_ids: facts["owned_agent_ids"],
          invoices: facts["invoices"]&.map { |invoice| Invoice.new(id: invoice["id"], company_id: invoice["company_id"]) }
        )
      rescue JSON::ParserError
        raise Unavailable, "reference response is not JSON"
      end

      def valid_facts?(facts, company_id)
        facts.is_a?(Hash) &&
          facts["company_id"] == company_id &&
          facts["edit_days"].is_a?(Integer) &&
          list_of?(facts["users"]) { |user| valid_user?(user) } &&
          list_of?(facts["projects"]) { |project| valid_project?(project, company_id) } &&
          list_of?(facts["missing_project_ids"]) { |id| id.is_a?(Integer) } &&
          list_of?(facts["agents"]) { |agent| valid_agent?(agent) } &&
          valid_owned_agent_ids?(facts) &&
          valid_invoices?(facts, company_id)
      end

      # Absent is allowed, for a monolith deployed before the field existed;
      # present, it must be a list of Integers.
      def valid_owned_agent_ids?(facts)
        !facts.key?("owned_agent_ids") || list_of?(facts["owned_agent_ids"]) { |id| id.is_a?(Integer) }
      end

      # Absent is allowed, as for owned_agent_ids; present, every invoice must
      # belong to the path company, so a crossed answer never grants another
      # company's invoice.
      def valid_invoices?(facts, company_id)
        !facts.key?("invoices") || list_of?(facts["invoices"]) { |invoice| valid_invoice?(invoice, company_id) }
      end

      def valid_invoice?(invoice, company_id)
        invoice.is_a?(Hash) && invoice["id"].is_a?(Integer) && invoice["company_id"] == company_id
      end

      def valid_agent?(agent)
        agent.is_a?(Hash) && agent["id"].is_a?(Integer) && agent["user_id"].is_a?(Integer)
      end

      def valid_user?(user)
        user.is_a?(Hash) && user["id"].is_a?(Integer) && user["role"].is_a?(String)
      end

      def valid_project?(project, company_id)
        project.is_a?(Hash) &&
          project["id"].is_a?(Integer) &&
          project["company_id"] == company_id &&
          [true, false].include?(project["billable"]) &&
          list_of?(project["member_user_ids"]) { |id| id.is_a?(Integer) }
      end

      def list_of?(value, &valid)
        value.is_a?(Array) && value.all?(&valid)
      end
  end
end
