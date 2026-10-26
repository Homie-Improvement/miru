# frozen_string_literal: true

require "net/http"

module Timekeeping
  # Reads entries from the Timekeeping service's entry API
  # (contracts/timekeeping/entry_api.yml) on behalf of one user in one
  # company. Every HTTP call to that API lives here, so callers see plain
  # entry Hashes and this class's Error, never a Net:: exception.
  #
  # It authenticates with a user token minted for that user and company, so
  # Timekeeping applies the same visibility rules it applies to the user's
  # own requests. It never retries and never answers from another store: a
  # failure raises, so a caller cannot mistake a stale copy for the owner.
  class EntryApiClient
    BASE_URL_ENV = "TIMEKEEPING_BASE_URL"
    # Set to "true" only once the running Timekeeping refuses read tokens on
    # write routes. It chooses only the token's purpose claim: read and write
    # tokens carry the same role (docs/architecture/timekeeping-soa.md,
    # section 6.2).
    READ_TOKENS_ENV = "TIMEKEEPING_READ_TOKENS_ENABLED"
    INDEX_PATH = "/v1/companies/%<company_id>d/entries"
    SHOW_PATH = "/v1/companies/%<company_id>d/entries/%<entry_id>d"
    TIMEOUT_SECONDS = 5

    class Error < StandardError; end

    def initialize(base_url: ENV[BASE_URL_ENV])
      @base_url = base_url.to_s
    end

    # Returns the entry Hashes of the list route's "entries" answer.
    # The token speaks for the acting user, whose employment the token
    # requires, while user_id only filters the list: the user being read may
    # have left the company. Either way the token carries any owner or admin
    # role the acting user holds in the company, the same roles that let the
    # index controllers read a colleague. With READ_TOKENS_ENV on, it is a read
    # token, which Timekeeping refuses for writes; with it off, it is the
    # default write token.
    def list_entries(company_id:, user_id:, from:, to:, acting_user_id: user_id)
      raise Error, "#{BASE_URL_ENV} is not set" if @base_url.blank?

      company = Company.find(company_id)
      token = UserToken.mint(user: company.users.find(acting_user_id), company:, purpose: token_purpose)
      response = get(list_uri(company_id:, user_id:, from:, to:), token)
      raise Error, "Timekeeping entry list answered #{response.code}" unless response.is_a?(Net::HTTPOK)

      JSON.parse(response.body).fetch("entries")
    rescue SystemCallError, IOError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError, Net::ProtocolError,
           JSON::ParserError, KeyError => error
      raise Error, "Timekeeping entry list failed: #{error.class}"
    end

    # Returns the entry Hash of the show route, read for the acting user with
    # a write token, because the caller is about to change the entry. The
    # request carries request_id as X-Request-Id, so the lookup and the write
    # that follows it trace to the same monolith request. A missing entry, or
    # one of another company, raises ActiveRecord::RecordNotFound; a refused
    # actor raises EntryWriteClient::Forbidden.
    def show_entry(company_id:, entry_id:, acting_user_id:, request_id:)
      raise Error, "#{BASE_URL_ENV} is not set" if @base_url.blank?

      company = Company.find(company_id)
      # Any user, so an actor outside the company reaches mint's
      # NotInCompanyError (403) rather than a 404 for the entry.
      token = UserToken.mint(user: User.find(acting_user_id), company:)
      uri = URI.join(@base_url, format(SHOW_PATH, company_id:, entry_id:))
      response = get(uri, token, request_id:)
      raise show_refusal(response) unless response.is_a?(Net::HTTPOK)

      JSON.parse(response.body)
    rescue UserToken::NotInCompanyError => error
      raise EntryWriteClient::Forbidden, "Timekeeping entry token refused: #{error.class}"
    rescue UserToken::MissingKeyError, SystemCallError, IOError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError,
           Net::ProtocolError, JSON::ParserError => error
      raise Error, "Timekeeping entry show failed: #{error.class}"
    end

    private

      def show_refusal(response)
        case response.code.to_i
        when 404 then ActiveRecord::RecordNotFound.new("Couldn't find TimesheetEntry", "TimesheetEntry")
        when 403 then EntryWriteClient::Forbidden.new("Timekeeping entry show answered 403")
        else Error.new("Timekeeping entry show answered #{response.code}")
        end
      end

      def token_purpose
        ENV[READ_TOKENS_ENV] == "true" ? :read : :write
      end

      def list_uri(company_id:, user_id:, from:, to:)
        uri = URI.join(@base_url, format(INDEX_PATH, company_id:))
        uri.query = URI.encode_www_form(user_id:, from: from.to_date.iso8601, to: to.to_date.iso8601)
        uri
      end

      def get(uri, token, request_id: nil)
        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = "Bearer #{token}"
        request["X-Request-Id"] = request_id.to_s unless request_id.nil?
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                            open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS) do |http|
          http.request(request)
        end
      end
  end
end
