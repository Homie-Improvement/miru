# frozen_string_literal: true

require "bigdecimal"
require "json"

module Timekeeping
  module Handoff
    # Writes values into hand-built SQL and JSON text without the losses
    # Active Record's own casts cause: a jsonb decimal rounded to a Float or
    # written as a quoted string, JSON null merged with SQL NULL, and -0.0
    # stored as 0. Every handoff path that writes rows uses it, so a value
    # copied between the two applications comes back unchanged.
    module LosslessSql
      module_function

      # JSON text with each BigDecimal written as a bare number. The default
      # encoders write a BigDecimal as a quoted string.
      def json_text(value)
        case value
        when Hash then "{#{value.map { |key, item| "#{JSON.generate(key.to_s)}:#{json_text(item)}" }.join(',')}}"
        when Array then "[#{value.map { |item| json_text(item) }.join(',')}]"
        when BigDecimal then value.to_s("F")
        when Checkpoint::JSON_NULL then "null"
        else JSON.generate(value.as_json)
        end
      end

      # The SQL literal for value in column, cast to the column's type.
      #
      # Floats go in as quoted text: Float#to_s is the shortest decimal that
      # reads back to the same bits, and an unquoted -0.0 would be parsed as
      # the negation of the number zero and stored as 0.
      def literal(connection, value, column)
        # Column#sql_type names an array column's element type only.
        sql_type = column.array? ? "#{column.sql_type}[]" : column.sql_type
        literal =
          if value.is_a?(Float)
            connection.quote(value.to_s)
          elsif column.type == :jsonb && !value.nil?
            connection.quote(json_text(value))
          else
            connection.quote(connection.lookup_cast_type(sql_type).serialize(value))
          end
        "#{literal}::#{sql_type}"
      end
    end
  end
end
