# frozen_string_literal: true

module Timekeeping
  # Sets timesheet_entries.company_id to the company of the entry's project's
  # client, for every row whose value is missing or differs. It is plain SQL,
  # so it runs no model callback: updated_at and the audit log stay untouched,
  # and no other column is written. It joins the raw tables, so discarded
  # entries, projects and clients are covered too. Running it again changes
  # only rows that went wrong since, so it is safe to repeat.
  #
  # It updates one id range per statement. Outside a transaction each range
  # commits on its own, so no lock on timesheet_entries is held for the whole
  # table, and a run stopped part-way leaves every row either untouched or
  # correct.
  #
  # The backfill migration calls it, and so does the
  # timekeeping:backfill_entry_company_ids task, which repairs rows that an
  # application process without the company_id callback wrote during a deploy.
  class EntryCompanyBackfill
    BATCH_SIZE = 10_000

    BATCH_SQL = <<~SQL.squish
      UPDATE timesheet_entries
      SET company_id = clients.company_id
      FROM projects
      INNER JOIN clients ON clients.id = projects.client_id
      WHERE projects.id = timesheet_entries.project_id
        AND timesheet_entries.id > %<after_id>d AND timesheet_entries.id <= %<up_to_id>d
        AND timesheet_entries.company_id IS DISTINCT FROM clients.company_id
    SQL

    # Returns the number of rows it changed.
    def self.call(connection)
      max_id = connection.select_value("SELECT max(id) FROM timesheet_entries").to_i

      (0...max_id).step(BATCH_SIZE).sum do |after_id|
        connection.exec_update(format(BATCH_SQL, after_id:, up_to_id: after_id + BATCH_SIZE))
      end
    end
  end
end
