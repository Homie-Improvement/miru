# frozen_string_literal: true

# Fills timesheet_entries.company_id, added by the previous migration, from
# project -> client -> company. It runs outside a DDL transaction so each id
# range commits on its own and no lock on the whole table is held while rows
# are rewritten. Rolling back needs no work: the previous migration's rollback
# drops the column.
class BackfillTimesheetEntryCompanyIds < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    Timekeeping::EntryCompanyBackfill.call(connection)
  end

  def down; end
end
