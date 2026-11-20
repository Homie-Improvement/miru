# frozen_string_literal: true

# Decides which cross-tenant cases the Timekeeping tenant guard owes. Every
# route in the contracts carries some set of foreign identifier kinds, read
# from its path, query and request fields; the guard owes one case per route
# and kind, and one no-identifier case for a route that carries none.
#
# The derivation fails closed: a route key or field name it cannot classify
# raises, so a new identifier added to a contract can never be read as
# carrying nothing.
module TenantGuardSurfaces
  class NoRoutesError < ArgumentError; end
  class UnknownFieldError < ArgumentError; end

  # Route keys the derivation understands. Response keys describe what comes
  # back, never an identifier the requester sends, so they are not read.
  ROUTE_KEYS = %w[method path query request_fields response_fields response_entry_fields].freeze

  # Field and path parameter names that carry a foreign identifier.
  IDENTIFIER_FIELDS = {
    "entry_id" => %i[entry_id],
    "entries" => %i[entry_id],
    "entry_ids" => %i[entry_id],
    "invoice_id" => %i[invoice_id],
    "operation_id" => %i[operation_id]
  }.transform_values(&:freeze).freeze

  # Names that mean an identifier only inside one contract's body lists.
  CONTRACT_IDENTIFIER_FIELDS = {
    entry_snapshots: { "id" => %i[entry_id].freeze }.freeze
  }.freeze

  # Every other name must be listed here. The six snapshot entry columns at
  # the end are carried by entry_snapshots.yml entry_fields and are neither
  # identifiers nor entry_api entry body fields; without them the real
  # contracts would raise. The entry_api entry_*_fields names are read from
  # the contract itself (see entry_body_fields).
  NON_IDENTIFIER_FIELDS = %w[
    company_id project_id user_id agent_id generation disposition through from to project_ids schema_version
    review_status locked version discarded_at created_at updated_at
  ].freeze

  ENTRY_BODY_FIELDS_PATTERN = /\Aentry_\w+_fields\z/

  # Contract-level lists a route's body is read from, as key paths into the contract.
  BODY_LISTS = {
    entry_api: {
      create: [%w[request entry_required_fields], %w[request entry_optional_fields]],
      update: [%w[request entry_required_fields], %w[request entry_optional_fields]],
      bulk_move: [%w[request bulk_move_fields]],
      bulk_delete: [%w[request bulk_delete_fields]]
    },
    entry_snapshots: {
      deliver: [%w[entry_fields]]
    }
  }.freeze

  # idempotency.yml key_sources values. A header key makes every write route
  # of the contract carry an idempotency key; a body operation_id is itself
  # the key, so that field carries both kinds.
  KEY_SOURCES = {
    "Idempotency-Key header" => :header,
    "operation_id in the body" => :operation_id
  }.freeze

  WRITE_METHODS = %w[POST PATCH DELETE].freeze

  # Contracts whose write routes take no idempotency key. idempotency.yml
  # key_sources names none for handoff, whose commands are repeatable by rule
  # (handoff.yml rules.repeatable). Any other contract with a write route and
  # no key source raises, so a missing key source cannot drop key pairs.
  KEYLESS_CONTRACTS = %i[handoff].freeze

  # The pairs a replay counts toward. Every other pair needs a probe.
  REPLAY_PAIRS = [
    %i[entry_api create idempotency_key],
    %i[entry_api update idempotency_key],
    %i[entry_api bulk_move idempotency_key],
    %i[reservations prepare idempotency_key],
    %i[reservations mark_billed idempotency_key],
    %i[reservations detach_entries idempotency_key],
    %i[entry_snapshots deliver idempotency_key]
  ].map(&:freeze).freeze

  PATH_PARAM_PATTERN = /\{(\w+)\}/
  QUERY_STRING_NAME_PATTERN = /\A(\w+)=/

  class << self
    # Returns sorted, frozen [contract_name, route_name, kind] entries. kind is
    # :entry_id, :invoice_id, :operation_id, :idempotency_key, or :none for a
    # route that carries no identifier.
    def pairs(contracts)
      key_sources = key_sources(contracts)
      non_identifiers = NON_IDENTIFIER_FIELDS + entry_body_fields(contracts)

      entries = contracts.flat_map do |contract_name, contract|
        check_body_lists_claimed!(contract_name, contract)
        contract.fetch("routes", {}).flat_map do |route_name, route|
          kinds = route_kinds(contract_name, contract, route_name.to_sym, route, key_sources, non_identifiers)
          (kinds.empty? ? [:none] : kinds).map { |kind| [contract_name, route_name.to_sym, kind] }
        end
      end
      raise NoRoutesError, "the Timekeeping contracts declare no routes" if entries.empty?

      entries.sort_by { |entry| entry.map(&:to_s) }.map(&:freeze).freeze
    end

    # Returns the routes and the pairs no case covers. Any case names its
    # route; a probe counts toward every pair it covers, and a replay only
    # toward the pairs in REPLAY_PAIRS.
    def uncovered(contracts:, cases:)
      owed = pairs(contracts)
      covered = cases.flat_map do |kase|
        kase.covers.map { |kind| [kase.contract, kase.route, kind] }
                   .select { |pair| kase.mode == :probe || REPLAY_PAIRS.include?(pair) }
      end
      cased_routes = cases.map { |kase| [kase.contract, kase.route] }

      { routes: owed.map { |pair| pair.first(2) }.uniq - cased_routes, pairs: owed - covered }
    end

    private

      def route_kinds(contract_name, contract, route_name, route, key_sources, non_identifiers)
        unknown_keys = route.keys - ROUTE_KEYS
        unless unknown_keys.empty?
          raise UnknownFieldError, "#{contract_name}.#{route_name} has unrecognised route keys #{unknown_keys.join(", ")}"
        end

        key_source = key_sources[contract_name]
        write = WRITE_METHODS.include?(route.fetch("method"))
        if write && key_source.nil? && !KEYLESS_CONTRACTS.include?(contract_name)
          raise UnknownFieldError, "#{contract_name}.#{route_name} is a write route with no idempotency key source"
        end

        names = route_field_names(contract_name, contract, route_name, route)
        kinds = names.flat_map do |name|
          field_kinds(contract_name, route_name, name, key_source, non_identifiers)
        end
        kinds << :idempotency_key if key_source == :header && write
        kinds.uniq
      end

      def route_field_names(contract_name, contract, route_name, route)
        route.fetch("path").scan(PATH_PARAM_PATTERN).flatten +
          query_names(contract_name, route_name, route["query"]) +
          route.fetch("request_fields", []) +
          body_list_names(contract_name, contract, route_name)
      end

      def query_names(contract_name, route_name, query)
        case query
        when nil then []
        when Array then query
        when String then [query[QUERY_STRING_NAME_PATTERN, 1] || unreadable_query!(contract_name, route_name, query)]
        else unreadable_query!(contract_name, route_name, query)
        end
      end

      def unreadable_query!(contract_name, route_name, query)
        raise UnknownFieldError, "#{contract_name}.#{route_name} has an unreadable query #{query.inspect}"
      end

      def body_list_names(contract_name, contract, route_name)
        BODY_LISTS.fetch(contract_name, {}).fetch(route_name, []).flat_map do |key_path|
          contract.dig(*key_path) ||
            raise(UnknownFieldError, "#{contract_name} has no #{key_path.join(".")} list for #{route_name}")
        end
      end

      def field_kinds(contract_name, route_name, name, key_source, non_identifiers)
        kinds = CONTRACT_IDENTIFIER_FIELDS.fetch(contract_name, {})[name] || IDENTIFIER_FIELDS[name]
        if kinds.nil?
          return [] if non_identifiers.include?(name)

          raise UnknownFieldError, "#{contract_name}.#{route_name} carries unlisted field #{name.inspect}"
        end

        body_key = key_source == :operation_id && name == "operation_id"
        body_key ? kinds + [:idempotency_key] : kinds
      end

      # A request list no route reads would hide its fields from the guard.
      def check_body_lists_claimed!(contract_name, contract)
        claimed = BODY_LISTS.fetch(contract_name, {}).values.flatten(1)
                            .filter_map { |key_path| key_path.last if key_path.first == "request" }
        unclaimed = contract.fetch("request", {}).keys - claimed
        return if unclaimed.empty?

        raise UnknownFieldError, "#{contract_name} request lists #{unclaimed.join(", ")} belong to no route"
      end

      def key_sources(contracts)
        contracts.fetch(:idempotency).fetch("key_sources").to_h do |contract_name, source|
          key = source.fetch("key")
          [contract_name.to_sym, KEY_SOURCES.fetch(key) { raise UnknownFieldError, "unknown key source #{key.inspect}" }]
        end
      end

      def entry_body_fields(contracts)
        request = contracts.fetch(:entry_api, {}).fetch("request", {})
        request.select { |list_name, _names| ENTRY_BODY_FIELDS_PATTERN.match?(list_name) }.values.flatten
      end
  end
end
