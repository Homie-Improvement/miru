# frozen_string_literal: true

module Timekeeping
  module Handoff
    # The file form of the invoice_operation_intents rows frozen at the
    # checkpoint, which a resumed handoff compares the current intents
    # against. Reconciliation compares each field with ==, so every column is
    # read back as the type a database read gives: plain JSON would leave a
    # time as a string. Each column of Reconciliation::INTENT_COLUMNS has one
    # type below, and a value of any other type refuses the whole file.
    module SourceIntentsFile
      # Raised when the text is not an intents file this module wrote.
      class Unreadable < StandardError; end

      TYPES = {
        integer: { dump: ->(value) { integer!(value) }, load: ->(value) { integer!(value) } },
        string: { dump: ->(value) { string!(value) }, load: ->(value) { string!(value) } },
        integer_array: {
          dump: ->(value) { value.map { |element| integer!(element) } },
          load: ->(value) { value.map { |element| integer!(element) } }
        },
        time: { dump: ->(value) { value.utc.iso8601(6) }, load: ->(value) { Time.iso8601(string!(value)).utc } },
        optional_time: {
          dump: ->(value) { value&.utc&.iso8601(6) },
          load: ->(value) { value.nil? ? nil : Time.iso8601(string!(value)).utc }
        }
      }.freeze

      COLUMN_TYPES = {
        "id" => :integer, "company_id" => :integer, "invoice_id" => :integer, "operation_id" => :string,
        "generation" => :integer, "desired_entry_ids" => :integer_array, "disposition" => :string,
        "state" => :string, "created_at" => :time, "finished_at" => :optional_time
      }.freeze

      module_function

      def dump(rows)
        JSON.generate("rows" => rows.map { |row| convert(row, :dump) })
      end

      def load(text)
        JSON.parse(text).fetch("rows").map { |row| convert(row, :load) }
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError, NoMethodError => error
        raise Unreadable, "the source intents file is unreadable: #{error.class}"
      end

      def convert(row, direction)
        Reconciliation::INTENT_COLUMNS.index_with do |column|
          TYPES.fetch(COLUMN_TYPES.fetch(column)).fetch(direction).call(row.fetch(column))
        end
      end

      def integer!(value)
        raise TypeError, "expected an integer" unless value.is_a?(Integer)

        value
      end

      def string!(value)
        raise TypeError, "expected a string" unless value.is_a?(String)

        value
      end

      private_class_method :convert, :integer!, :string!
    end
  end
end
