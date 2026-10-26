# frozen_string_literal: true

module Timekeeping
  # The entry list a user reads right after writing
  # (docs/architecture/timekeeping-soa.md section 3.3). It reads the current
  # owner, never the timesheet_entries projection once that is only a copy,
  # so a new entry shows at once even while snapshot delivery is paused.
  #
  # Each call reads exactly one store, chosen by Timekeeping::EntryOwner, and
  # never merges stores or falls back to another: a stale or partial list
  # would look current to the user.
  #
  # Every store's answer comes back as TimesheetEntry records with project,
  # client, user and agent loaded, newest work_date first, so
  # TimesheetEntriesPresenter renders them exactly as it renders
  # timesheet_entries rows.
  module EntryReader
    module_function

    # acting_user_id names who is reading, which can differ from user_id when
    # an owner or admin reads another user's entries, including a user who has
    # since left the company. It defaults to the user being read.
    def list(company_id:, user_id:, from:, to:, acting_user_id: user_id, ownership: TimekeepingOwnership.current,
             timekeeping_client: EntryApiClient.new)
      company = Company.find(company_id)

      case EntryOwner.for(ownership)
      when :legacy
        legacy_entries(company:, user_id:, from:, to:)
      when :prepared
        rows = PreparedEntry.where(company_id:, user_id:, discarded_at: nil, work_date: from..to).map(&:attributes)
        hydrate(rows, company:, user_id:)
      when :timekeeping
        hydrate(timekeeping_client.list_entries(company_id:, user_id:, from:, to:, acting_user_id:), company:, user_id:)
      end
    end

    def legacy_entries(company:, user_id:, from:, to:)
      TimesheetEntry.kept.where(user_id:).includes(:user, project: :client)
        .in_workspace(company)
        .during(from, to)
    end

    # Builds read-only, unsaved TimesheetEntry records from an owner's entry
    # Hashes. A row is dropped when it names another company, another user,
    # or a project or user that is not this company's: the owner's answer is
    # not trusted to stay inside the company, and an unscoped lookup by id
    # would show another company's project or user name. Associations are set
    # from company-scoped lookups, so nothing loads by a bare id later.
    def hydrate(rows, company:, user_id:)
      rows = rows.select do |row|
        row["company_id"] == company.id && row["user_id"] == user_id && row["discarded_at"].nil?
      end
      projects = company.projects.includes(:client).where(id: rows.pluck("project_id")).index_by(&:id)
      users = company.users.where(id: user_id).index_by(&:id)
      agents = company.agents.where(id: rows.pluck("agent_id").compact).index_by(&:id)

      rows.filter_map do |row|
        project = projects[row["project_id"]]
        user = users[row["user_id"]]
        next unless project && user

        build_entry(row, project:, user:, agent: agents[row["agent_id"]])
      end.sort_by { |entry| [entry.work_date, entry.id] }.reverse
    end

    def build_entry(row, project:, user:, agent:)
      TimesheetEntry.new(row.slice(*TimesheetEntry.attribute_names)).tap do |entry|
        entry.association(:project).target = project
        entry.association(:user).target = user
        entry.association(:agent).target = agent
        entry.readonly!
      end
    end
  end
end
