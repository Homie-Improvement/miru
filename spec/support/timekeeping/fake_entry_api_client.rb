# frozen_string_literal: true

require "uri"

require_relative "contract"
require_relative "fake_timekeeping"

module TimekeepingContract
  # Stands in for Timekeeping::EntryApiClient by calling a FakeTimekeeping's
  # list route, so reader and request specs read the fake owner through the
  # same route, query and answer shape the real client uses.
  #
  # The fake only knows users it created, so each call registers an acting
  # owner in the requested company and narrows the list to the real user_id.
  class FakeEntryApiClient
    ACTING_ROLE = "owner"

    def initialize(timekeeping:)
      @timekeeping = timekeeping
      @index_path = TimekeepingContract.load(:entry_api).dig("routes", "index", "path")
    end

    # The acting user the real client mints its token for is not used: the
    # fake always reads as a fresh owner of the company.
    def list_entries(company_id:, user_id:, from:, to:, **)
      token = @timekeeping.issue_token(@timekeeping.add_user(company_id:, role: ACTING_ROLE))
      query = URI.encode_www_form(user_id:, from: from.to_date.iso8601, to: to.to_date.iso8601)
      path = "#{@index_path.sub("{company_id}", company_id.to_s)}?#{query}"
      response = @timekeeping.call("GET", path, headers: { "Authorization" => "Bearer #{token}" })
      raise Timekeeping::EntryApiClient::Error, "fake Timekeeping answered #{response.status}" unless response.status == 200

      response.body.fetch("entries")
    end
  end
end
