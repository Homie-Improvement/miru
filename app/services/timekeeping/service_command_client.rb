# frozen_string_literal: true

require "net/http"

module Timekeeping
  # Sends a background service command to the Timekeeping service
  # (contracts/timekeeping/reservations.yml) while Timekeeping owns the
  # entries. Every HTTP call for these routes lives here, so callers see the
  # answer or one of the errors below, never a Net:: exception.
  #
  # It authenticates with a Timekeeping::ServiceToken minted for the one
  # company and the one operation of each call, never with the shared
  # TIMEKEEPING_SERVICE_TOKEN or a user token. Error messages carry only the
  # route and status or the exception class, never the token or the answer.
  #
  # It never retries. A resend of one command carries the same operation_id,
  # so Timekeeping replays its stored receipt instead of writing twice.
  class ServiceCommandClient
    DETACH_ENTRIES_PATH = "/v1/companies/%<company_id>d/agents/%<agent_id>d/detach-entries"

    def initialize(base_url: ENV[EntryApiClient::BASE_URL_ENV])
      @base_url = base_url.to_s
    end

    # Returns how many entries Timekeeping detached from the agent.
    def detach_agent_entries(company_id:, agent_id:, generation:, operation_id:, request_id:)
      path = format(DETACH_ENTRIES_PATH, company_id:, agent_id:)
      answer = post(path, company_id:, operation: ServiceToken::DETACH_ENTRIES, request_id:,
                          body: { "operation_id" => operation_id, "generation" => generation })
      detached = answer["detached"] if answer.is_a?(Hash)
      raise EntryWriteClient::Error, "Timekeeping detach-entries answer had no detached count" unless detached.is_a?(Integer)

      detached
    end

    private

      def post(path, company_id:, operation:, request_id:, body:)
        raise EntryWriteClient::Error, "#{EntryApiClient::BASE_URL_ENV} is not set" if @base_url.blank?

        request = Net::HTTP::Post.new(URI.join(@base_url, path))
        request["Authorization"] = "Bearer #{token_for(company_id, operation)}"
        request["X-Request-Id"] = request_id.to_s
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)

        response = send_request(request)
        raise refusal_for(operation, response) unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      rescue SystemCallError, IOError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError, Net::ProtocolError,
             JSON::ParserError => error
        raise EntryWriteClient::Error, "Timekeeping #{operation} failed: #{error.class}"
      end

      def token_for(company_id, operation)
        ServiceToken.mint(company_id:, operations: [operation])
      rescue UserToken::MissingKeyError => error
        raise EntryWriteClient::Error, "Timekeeping service token unavailable: #{error.class}"
      end

      # A stale generation is the gateway's own refusal; every other non-2xx
      # answer means the command did not run, so the caller's destroy aborts.
      def refusal_for(operation, response)
        status = response.code.to_i
        return Gateway::StaleGeneration.new if status == 409 && reason_of(response) == "stale_generation"

        EntryWriteClient::Error.new("Timekeeping #{operation} answered #{status}")
      end

      def reason_of(response)
        parsed = JSON.parse(response.body.to_s)
        parsed["reason"] if parsed.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end

      def send_request(request)
        uri = request.uri
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                            open_timeout: EntryApiClient::TIMEOUT_SECONDS,
                                            read_timeout: EntryApiClient::TIMEOUT_SECONDS) do |http|
          http.request(request)
        end
      end
  end
end
