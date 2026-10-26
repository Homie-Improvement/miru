# frozen_string_literal: true

module TimekeepingRules
  # The authorization decisions of an entry write, over plain values. Each
  # function reads no clock, database or request: the writer passes in the
  # acting user and role, the reference facts and the locked rows. The rules
  # themselves are EntryRules; this module only turns request values into the
  # types those rules compare, so every writer coerces them alike.
  module EntryDecision
    ID = /\A[0-9]{1,19}\z/

    # Stands in for a user_id that is not an id at all. It equals no user id,
    # so EntryRules answers it as it answers a user who does not exist:
    # :not_found for an owner or admin, :forbidden for an employee.
    UNKNOWN_USER = :unknown_user

    module_function

    # A5. EntryRules compares ids without coercion ("7" never equals 7), and
    # a JSON body may send the id as a string, so the requested id becomes an
    # Integer first.
    def target_user(acting_user_id:, role:, requested_user_id:, company_user_ids:)
      EntryRules.target_user(
        acting_user_id:,
        role:,
        requested_user_id: user_id(requested_user_id),
        company_user_ids:
      )
    end

    # A missing If-Match leaves the version unchecked, as the contract fake
    # does. A value that is not a plain integer never matches a version.
    def version(if_match:, current_version:)
      return :ok if if_match.nil?
      return :ok if ID.match?(if_match.to_s) && Integer(if_match.to_s, 10) == current_version

      :version_conflict
    end

    # A2 to A4, A6, A7 for an update or delete of one locked entry. entry: is
    # { id:, user_id:, work_date:, bill_status:, locked: }.
    def change(action:, bill_status:, role:, acting_user_id:, entry:, edit_days:, today:)
      EntryRules.change_decision(
        caller: EntryRules::USER_DELEGATED,
        change: { action:, bill_status: },
        role:, acting_user_id:, entry:, edit_days:, today:
      )
    end

    # A9 for a bulk move or delete: :forbidden refuses the whole request,
    # otherwise each entry id maps to :apply or :skip (an employee's move of a
    # reserved entry). Only entries the caller may see are passed in.
    def bulk(action:, role:, acting_user_id:, entries:, edit_days:, today:)
      EntryRules.bulk_decision(
        caller: EntryRules::USER_DELEGATED,
        change: { action: },
        role:, acting_user_id:, entries:, edit_days:, today:
      )
    end

    def user_id(value)
      return value if value.nil? || value.is_a?(Integer)
      return Integer(value, 10) if value.is_a?(String) && ID.match?(value)

      UNKNOWN_USER
    end
    private_class_method :user_id
  end
end
