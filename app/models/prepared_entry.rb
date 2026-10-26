# frozen_string_literal: true

# A row of the prepared monolith's entries table
# (docs/architecture/timekeeping-soa.md section 10.1). That table is written
# only by the prepared monolith's own write path, so this model is read-only.
class PreparedEntry < ApplicationRecord
  self.table_name = "entries"

  def readonly?
    true
  end
end
