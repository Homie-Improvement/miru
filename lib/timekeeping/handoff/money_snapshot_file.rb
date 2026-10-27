# frozen_string_literal: true

module Timekeeping
  module Handoff
    # The file form of the step 2 money snapshots, { company_id => FinancialSnapshot },
    # that a resumed handoff compares against. Plain JSON would turn a
    # BigDecimal into a rounded float, a symbol into a string, and an integer
    # company id into a string key, so every value and every key element is
    # written with its type and read back as exactly that type. A snapshot
    # read back therefore compares equal to the one taken, value for value.
    module MoneySnapshotFile
      # Raised when the text is not a snapshot file this module wrote.
      class Unreadable < StandardError; end

      TYPED = {
        "decimal" => ->(text) { BigDecimal(text) },
        "integer" => ->(text) { Integer(text, 10) },
        "string" => ->(text) { String(text) },
        "symbol" => ->(text) { String(text).to_sym }
      }.freeze

      module_function

      def dump(snapshots_by_company)
        companies = snapshots_by_company.map do |company_id, snapshot|
          values = snapshot.fetch(:values).map do |key, value|
            { "key" => key.map { |element| encode(element) }, "value" => encode(value) }
          end
          { "company_id" => Integer(company_id), "snapshot_company_id" => Integer(snapshot.fetch(:company_id)),
            "values" => values }
        end
        JSON.generate("companies" => companies)
      end

      def load(text)
        JSON.parse(text).fetch("companies").to_h do |company|
          values = company.fetch("values").to_h do |pair|
            [pair.fetch("key").map { |element| decode(element) }.freeze, decode(pair.fetch("value"))]
          end
          snapshot = { company_id: integer!(company.fetch("snapshot_company_id")), values: values.freeze }.freeze
          [integer!(company.fetch("company_id")), snapshot]
        end
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError, NoMethodError => error
        raise Unreadable, "the money snapshot file is unreadable: #{error.class}"
      end

      def encode(value)
        case value
        when nil then nil
        when BigDecimal then { "type" => "decimal", "value" => value.to_s("F") }
        when Integer then { "type" => "integer", "value" => value.to_s }
        when Symbol then { "type" => "symbol", "value" => value.to_s }
        when String then { "type" => "string", "value" => value }
        else raise ArgumentError, "a money snapshot cannot hold a #{value.class}"
        end
      end

      def decode(tagged)
        return if tagged.nil?

        TYPED.fetch(tagged.fetch("type")).call(tagged.fetch("value"))
      end

      def integer!(value)
        raise TypeError, "expected an integer company id" unless value.is_a?(Integer)

        value
      end

      private_class_method :encode, :decode, :integer!
    end
  end
end
