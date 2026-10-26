# frozen_string_literal: true

module Timekeeping
  # Turns one reservation route or service command request into the checked
  # value Timekeeping::ReservationOperations or Timekeeping::ServiceCommands
  # takes. It refuses a body that holds a credential and checks every value's
  # shape, all before any transaction opens, so a value PostgreSQL cannot
  # store (a bad uuid, an id beyond bigint) is a bad request, never a failure
  # inside the write. It makes no access decision: Timekeeping::ReservationAccess
  # has already admitted the caller.
  module ReservationRequest
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    # The largest value a PostgreSQL bigint column holds.
    MAX_ID = (2**63) - 1
    DISPOSITIONS = [TimekeepingRules::ReservationDecision::ACTIVE_DISPOSITION, "retained"].freeze

    def self.id?(value)
      value.is_a?(Integer) && value.between?(1, MAX_ID)
    end

    # The shape each body field must have. generation is not here: it is
    # compared as sent, and one that is not the company's is stale_generation.
    # An entry listed twice is refused, so the stored desired set, which a
    # replay compares, has one spelling per set.
    FIELD_SHAPES = {
      "invoice_id" => ->(value) { id?(value) },
      "operation_id" => ->(value) { value.is_a?(String) && UUID.match?(value) },
      "disposition" => ->(value) { DISPOSITIONS.include?(value) },
      "entries" => ->(value) { value.is_a?(Array) && value.all? { |id| id?(id) } && value.uniq.size == value.size }
    }.freeze

    # For each route: the body fields it requires (request_fields of
    # contracts/timekeeping/reservations.yml, less generation), the command
    # that carries it out, and how the checked values become its request.
    # path_id is the invoice in a mark-billed path and the agent in a detach
    # path.
    ROUTES = {
      prepare: {
        fields: %w[invoice_id operation_id disposition entries],
        handler: ReservationOperations,
        build: ->(values) { reservation_request(values, disposition: values[:body]["disposition"], entry_ids: values[:body]["entries"]) }
      },
      commit: {
        fields: %w[invoice_id operation_id],
        handler: ReservationOperations,
        build: ->(values) { reservation_request(values) }
      },
      abort: {
        fields: %w[invoice_id operation_id],
        handler: ReservationOperations,
        build: ->(values) { reservation_request(values) }
      },
      mark_billed: {
        fields: %w[operation_id],
        handler: ServiceCommands,
        build: ->(values) { command_request(values) }
      },
      detach_entries: {
        fields: %w[operation_id],
        handler: ServiceCommands,
        build: ->(values) { command_request(values) }
      }
    }.each_value { |route| route.fetch(:fields).freeze && route.freeze }.freeze

    PATH_ID_ROUTES = %i[mark_billed detach_entries].freeze

    # The command class that carries out a route's request.
    def self.handler(route)
      ROUTES.fetch(route).fetch(:handler)
    end

    # Returns the route's request value, or the Timekeeping::WriteOutcome that
    # refuses it. Raises ActionController::BadRequest for a body that is not a
    # JSON object or holds a missing or wrongly shaped field.
    def self.build(route:, identity:, path_id:, raw_body:, bearer:)
      body = EntryCommand.parse_body(raw_body)
      if CredentialScan.found?(body, bearer:, held: Timekeeping.config.service_credentials,
                                     public_key: Environment.token_public_key)
        return WriteOutcome.refusal(:credential_in_body)
      end

      target_id = parse_path_id(route, path_id)
      return WriteOutcome.refusal(:not_found) if target_id == :invalid

      check_fields!(route, body)
      ROUTES.fetch(route).fetch(:build).call(
        { route:, body:, company_id: identity.company_id, actor_name: identity.service_name, target_id: }
      )
    end

    # A path id that cannot name a row is answered as not found, as a missing
    # one is.
    def self.parse_path_id(route, value)
      return unless PATH_ID_ROUTES.include?(route)
      return :invalid unless EntryCommand::ID.match?(value.to_s)

      id = Integer(value.to_s, 10)
      id?(id) ? id : :invalid
    end

    def self.check_fields!(route, body)
      invalid = ROUTES.fetch(route).fetch(:fields).reject { |field| body.key?(field) && FIELD_SHAPES.fetch(field).call(body[field]) }
      raise ActionController::BadRequest, "invalid #{invalid.join(", ")}" unless invalid.empty?
    end

    def self.reservation_request(values, disposition: nil, entry_ids: nil)
      body = values[:body]
      ReservationOperations::Request.new(
        route: values[:route], company_id: values[:company_id], actor_name: values[:actor_name],
        invoice_id: body["invoice_id"], operation_id: body["operation_id"], generation: body["generation"],
        disposition:, entry_ids:
      )
    end

    def self.command_request(values)
      body = values[:body]
      ServiceCommands::Request.new(
        route: values[:route], company_id: values[:company_id], actor_name: values[:actor_name],
        target_id: values[:target_id], operation_id: body["operation_id"], generation: body["generation"]
      )
    end

    private_class_method :id?, :parse_path_id, :check_fields!, :reservation_request, :command_request
  end
end
