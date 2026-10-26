# frozen_string_literal: true

require "bigdecimal"
require "json"

module Timekeeping
  module Handoff
    # Reads query results as checkpoint rows: string keys, Active Record's
    # casts for every column, and jsonb read exactly. Shared by every store
    # that exports a checkpoint, so they all read a jsonb cell the same way.
    module RowReader
      module_function

      def select_rows(connection, sql)
        result = connection.select_all(sql)
        jsonb_columns = result.columns.select { |column| result.column_types[column]&.type == :jsonb }

        result.cast_values.zip(result.rows).map do |values, raw_values|
          row = result.columns.zip(values).to_h
          jsonb_columns.each { |column| row[column] = parse_jsonb(raw_values[result.columns.index(column)]) }
          row
        end
      end

      # Active Record's jsonb cast turns every decimal into a Float, which
      # rounds a number finer than a double. BigDecimal keeps it as stored.
      # The cast also reads JSON null as nil, the same as SQL NULL.
      def parse_jsonb(text)
        return if text.nil?

        value = JSON.parse(text, decimal_class: BigDecimal)
        value.nil? ? Checkpoint::JSON_NULL : value
      end
    end
  end
end
