# frozen_string_literal: true

module Timekeeping
  # The legacy entry audits of docs/architecture/timekeeping-soa.md section
  # 10.3: the first checkpoint holds "the entry audit rows, with their original
  # timestamps and authors". Each `audits` row the `audited` gem wrote for a
  # TimesheetEntry becomes an entry_audits row of the checkpoint, or a refusal
  # for its company when it cannot load without losing or misfiling history.
  #
  # Pure: it reads plain hashes and touches no database.
  module LegacyAuditConversion
    # Timekeeping's actor type for a person, Timekeeping::EntryCommand::ACTOR_TYPE.
    USER_ACTOR_TYPE = "user"
    # The actor of a change no one authored, such as a seed load: the row has
    # no user and no username. entry_audits.actor_id is NOT NULL, so the
    # absence of an author needs a value of its own.
    SYSTEM_ACTOR = { "actor_type" => "system", "actor_id" => 0 }.freeze
    LEGACY_USER_TYPE = "User"
    COMPANY_TYPE = "Company"
    # The refusal key of an audit that names no company and whose entry is gone.
    UNKNOWN_COMPANY = "no company"

    # How each legacy action's audited_changes become before and after. A
    # create and a destroy store one value per field, an update stores
    # [old, new]. entry_audits.after is NOT NULL, so a destroy's after is an
    # empty object; a create's before is SQL NULL, as nothing came before it.
    CHANGE_SHAPES = {
      "create" => ->(changes) { [nil, changes] },
      "update" => ->(changes) { [changes.transform_values(&:first), changes.transform_values(&:last)] },
      "destroy" => ->(changes) { [changes, {}] }
    }.freeze

    module_function

    # audits: [{ id:, action:, associated_type:, associated_id:, auditable_id:,
    # user_type:, user_id:, username:, audited_changes:, created_at: }], the
    # legacy rows whose auditable type is TimesheetEntry, with audited_changes
    # already deserialized.
    # entries_by_id: { entry id => entry row as it goes into the checkpoint }.
    #
    # Returns { rows:, refusals: }: rows sorted by id, and refusals as
    # { company_id => [message] }, keyed by the entry's company when the entry
    # is in the checkpoint and by the audit's own company otherwise.
    def convert(audits:, entries_by_id:)
      rows = []
      refusals = Hash.new { |hash, key| hash[key] = [] }

      audits.sort_by { |audit| audit[:id] }.each do |audit|
        entry = entries_by_id[audit[:auditable_id]]
        problem = problem_with(audit, entry)
        if problem
          refusals[refusal_company(audit, entry)] << "audit #{audit[:id]} of entry #{audit[:auditable_id]}: #{problem}"
        else
          rows << row_for(audit, entry)
        end
      end

      { rows:, refusals: refusals.to_h }
    end

    # The first reason the audit cannot become a checkpoint row, or nil.
    def problem_with(audit, entry)
      company_id = audit_company_id(audit)
      return "the entry is not in the checkpoint, so the row could not load" unless entry
      return "names no company" unless company_id
      return "names company #{company_id}, but the entry belongs to company #{entry['company_id']}" if company_id != entry["company_id"]
      return "unknown action #{audit[:action].inspect}" unless CHANGE_SHAPES.key?(audit[:action])
      return "an update change is not an [old, new] pair" unless well_formed_changes?(audit)

      author_problem(audit)
    end

    # A named author must never be relabelled as the system actor, and
    # entry_audits has no column that can hold a name without a user id.
    def author_problem(audit)
      if audit[:user_id].nil?
        "author #{audit[:username].inspect} has no user id, and entry_audits cannot hold a name" if audit[:username].present?
      elsif audit[:user_type] != LEGACY_USER_TYPE
        "unknown author type #{audit[:user_type].inspect}"
      end
    end

    def well_formed_changes?(audit)
      return true unless audit[:action] == "update"

      audit[:audited_changes].to_h.values.all? { |change| change.is_a?(Array) && change.size == 2 }
    end

    def row_for(audit, entry)
      before, after = CHANGE_SHAPES.fetch(audit[:action]).call(audit[:audited_changes].to_h)

      {
        "id" => audit[:id],
        "company_id" => entry["company_id"],
        "entry_id" => entry["id"],
        **actor(audit),
        "action" => audit[:action],
        "before" => before,
        "after" => after,
        "entry_created_at" => entry["created_at"],
        "created_at" => audit[:created_at]
      }
    end

    def actor(audit)
      return SYSTEM_ACTOR if audit[:user_id].nil?

      { "actor_type" => USER_ACTOR_TYPE, "actor_id" => audit[:user_id] }
    end

    def audit_company_id(audit)
      audit[:associated_id] if audit[:associated_type] == COMPANY_TYPE
    end

    def refusal_company(audit, entry)
      entry&.fetch("company_id") || audit_company_id(audit) || UNKNOWN_COMPANY
    end
  end
end
