# frozen_string_literal: true

class AddAttemptedRowsToDataImports < ActiveRecord::Migration[8.1]
  # The CSV line numbers of the rows an import has tried to write. A rerun of a
  # failed import reads them to tell its own stored entries from other imports'.
  def change
    add_column :data_imports, :attempted_rows, :integer, array: true, default: [], null: false
  end
end
