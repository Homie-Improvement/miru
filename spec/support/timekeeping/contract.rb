# frozen_string_literal: true

require "yaml"

# Reads the Timekeeping contracts in contracts/timekeeping/. The fakes and the
# shared contract examples both take field lists, reasons and rules from here,
# so each fact of a contract is written once.
module TimekeepingContract
  CONTRACTS_DIR = File.expand_path("../../../contracts/timekeeping", __dir__)
  CONTRACT_NAMES = %i[entry_api reservations entry_snapshots idempotency].freeze

  class UnknownContractError < ArgumentError; end

  class << self
    # Returns the named contract as a deeply frozen Hash with string keys.
    def load(name)
      contract_name = name.to_sym
      unless CONTRACT_NAMES.include?(contract_name)
        raise UnknownContractError, "unknown Timekeeping contract #{name.inspect}; expected one of #{CONTRACT_NAMES.join(", ")}"
      end

      deep_freeze(YAML.safe_load_file(File.join(CONTRACTS_DIR, "#{contract_name}.yml"), aliases: false))
    end

    private

      def deep_freeze(value)
        case value
        when Hash
          value.each_value { |nested| deep_freeze(nested) }
        when Array
          value.each { |nested| deep_freeze(nested) }
        end
        value.freeze
      end
  end
end
