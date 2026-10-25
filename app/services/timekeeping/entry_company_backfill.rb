# frozen_string_literal: true

module Timekeeping
  # Sets timesheet_entries.company_id to the company of the entry's project's
  # client, for every row whose value is missing or differs. It is one SQL
  # UPDATE, so it runs no model callback: updated_at and the audit log stay
  # untouched, and no other column is written. It joins the raw tables, so
  # discarded entries, projects and clients are covered too. Running it again
  # changes only rows that went wrong since, so it is safe to repeat.
  #
  # The S2 migration calls it, and so does the
  # timekeeping:backfill_entry_company_ids task, which repairs rows that an
  # application process without the company_id callback wrote during a deploy.
  class EntryCompanyBackfill
    SQL = <<~SQL.squish
      UPDATE timesheet_entries
      SET company_id = clients.company_id
      FROM projects
      INNER JOIN clients ON clients.id = projects.client_id
      WHERE projects.id = timesheet_entries.project_id
        AND timesheet_entries.company_id IS DISTINCT FROM clients.company_id
    SQL

    # Returns the number of rows it changed.
    def self.call(connection)
      connection.exec_update(SQL)
    end
  end
end
