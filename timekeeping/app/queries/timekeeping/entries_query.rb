# frozen_string_literal: true

module Timekeeping
  # The entries a verified user may read. Every relation starts with the
  # token's company and leaves out discarded entries, then applies the A1
  # scope from TimekeepingRules. Query filters can only narrow that set: a
  # value of the wrong shape matches nothing rather than being ignored.
  module EntriesQuery
    ID = /\A[0-9]{1,19}\z/
    DATE = /\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/

    # Each list filter: the shape its value must have, and the condition it adds.
    FILTERS = {
      "user_id" => [ID, ->(value) { { user_id: Integer(value, 10) } }],
      "project_id" => [ID, ->(value) { { project_id: Integer(value, 10) } }],
      "from" => [DATE, ->(value) { { work_date: Date.iso8601(value).. } }],
      "to" => [DATE, ->(value) { { work_date: ..Date.iso8601(value) } }]
    }.freeze

    # An entry is locked exactly when a reservation row exists for it in the
    # same company. The stored entries.locked column is never read for this.
    RESERVED = <<~SQL.squish
      EXISTS (
        SELECT 1 FROM reservations
        WHERE reservations.company_id = entries.company_id
          AND reservations.entry_id = entries.id
      ) AS reserved
    SQL

    module_function

    def visible(company_id:, role:, acting_user_id:, filters: {})
      scope = TimekeepingRules::EntryRules.visible_scope(role:, acting_user_id:)
      relation = Entry.where(company_id:, discarded_at: nil)
      relation = relation.where(user_id: scope) unless scope == :company
      narrow(relation, filters).select("entries.*", RESERVED).order(:work_date, :id)
    end

    # nil for an id that is not a plain integer, so "12abc" never reads entry 12.
    def find_visible(id, **visibility)
      return unless ID.match?(id.to_s)

      visible(**visibility).find_by(id: Integer(id.to_s, 10))
    end

    def narrow(relation, filters)
      filters.to_h.reduce(relation) do |narrowed, (name, value)|
        next narrowed if value.to_s.empty?

        shape, condition = FILTERS.fetch(name.to_s)
        shape.match?(value.to_s) ? narrowed.where(condition.call(value.to_s)) : Entry.none
      end
    rescue Date::Error
      Entry.none
    end
  end
end
