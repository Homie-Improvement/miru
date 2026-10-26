# frozen_string_literal: true

# Adds the two facts the projection consumer and the entry reader need from
# the ownership record (docs/architecture/timekeeping-soa.md sections 5.4 and
# 10.1).
class AddProjectionColumnsToTimekeepingOwnership < ActiveRecord::Migration[8.1]
  MONOLITH_STORES = %w[legacy prepared].freeze

  def change
    # The outgoing owner's final outbox position P, captured at the freeze
    # step of a handoff. Null means no position was captured, and then no
    # previous-generation snapshot is accepted.
    add_column :timekeeping_ownership, :final_outbox_position, :bigint

    # Which monolith tables hold the entries while the monolith owns them:
    # timesheet_entries ('legacy') or the prepared local tables ('prepared').
    # The generation cannot tell them apart, because an aborted handoff keeps
    # the raised generation.
    add_column :timekeeping_ownership, :monolith_store, :string, null: false, default: "legacy"

    # The table holds one row, so validating the constraint locks nothing for long.
    safety_assured do
      add_check_constraint :timekeeping_ownership, "monolith_store IN (#{quoted_list(MONOLITH_STORES)})",
        name: "timekeeping_ownership_monolith_store_check"
    end
  end

  private

    def quoted_list(values)
      values.map { |value| connection.quote(value) }.join(", ")
    end
end
