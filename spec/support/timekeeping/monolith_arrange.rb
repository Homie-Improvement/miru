# frozen_string_literal: true

require "json"
require "rack/mock"
require_relative "client"

module TimekeepingContract
  # Sends contract requests to the monolith's own Rack application, so the
  # shared examples drive the real projection endpoint.
  class MonolithClient
    def initialize(app: Rails.application)
      @request = Rack::MockRequest.new(app)
    end

    def call(method, path, headers: {}, body: nil)
      env = headers.to_h.transform_keys { |name| "HTTP_#{name.upcase.tr("-", "_")}" }
      response = @request.request(method, path, env.merge("CONTENT_TYPE" => "application/json",
                                                           input: body.nil? ? "" : JSON.generate(body)))
      Response.new(status: response.status, body: response.body.empty? ? nil : JSON.parse(response.body))
    end
  end

  # The timekeeping_arrange the shared contract examples call, seeding the
  # monolith's real tables: the ownership record and the timesheet_entries
  # projection. The monolith knows one service identity, the token in
  # TIMEKEEPING_SERVICE_TOKEN, bound to no company and allowed to deliver.
  class MonolithArrange
    include FactoryBot::Syntax::Methods

    def initialize(private_key:)
      @private_key = private_key
      @user_companies = {}
    end

    def company
      create(:company).id
    end

    def user(company:, role:)
      user = create(:user)
      create(:employment, company_id: company, user:)
      user.add_role(role, Company.find(company))
      @user_companies[user.id] = company
      user.id
    end

    def project(company:)
      create(:project, client: create(:client, company_id: company)).id
    end

    def token_for(user_id)
      Timekeeping::UserToken.mint(user: User.find(user_id), company: Company.find(@user_companies.fetch(user_id)),
                                  private_key: @private_key)
    end

    def service_identity(company:, name:, operations:)
      unless company.nil? && operations == ["deliver"]
        raise ArgumentError, "the monolith has only the unbound Timekeeping service identity"
      end

      ENV.fetch(Internal::V1::BaseController::SERVICE_TOKEN_ENV)
    end

    def current_generation
      ownership.generation
    end

    def set_generation(generation)
      ownership.update!(generation:)
    end

    # The ownership record keeps one generation: during a handoff the
    # previous generation is always the current one minus one.
    def begin_handoff(previous_generation:, final_outbox_position:)
      raise ArgumentError, "previous_generation must be generation - 1" unless previous_generation == current_generation - 1

      ownership.update!(handoff_step: "freeze", final_outbox_position:)
    end

    def flip_ownership
      ownership.update!(handoff_step: nil, final_outbox_position: nil)
    end

    # The projected row in the snapshot's wire form, or nil when none exists.
    def projected_entry(entry_id)
      entry = TimesheetEntry.unscoped.find_by(id: entry_id)
      return nil unless entry

      entry.attributes.slice(*TimekeepingContract.load(:entry_snapshots).fetch("entry_fields")).transform_values do |value|
        case value
        when Time, ActiveSupport::TimeWithZone then value.utc.iso8601
        when Date then value.iso8601
        else value
        end
      end
    end

    private

      def ownership
        TimekeepingOwnership.current
      end
  end
end
