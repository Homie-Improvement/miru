# frozen_string_literal: true

class AddWrittenRowsToDataImports < ActiveRecord::Migration[8.1]
  # The CSV line numbers of the rows an import has written. A rerun of a failed
  # import reads them to tell its own stored entries from other imports' ones.
  def change
    add_column :data_imports, :written_rows, :integer, array: true, default: [], null: false
  end
end
