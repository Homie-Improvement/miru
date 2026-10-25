namespace :timekeeping do
  desc "Set timesheet_entries.company_id from project -> client -> company where it is missing or wrong"
  task backfill_entry_company_ids: :environment do
    fixed = Timekeeping::EntryCompanyBackfill.call(ActiveRecord::Base.connection)

    puts "fixed company_id on #{fixed} timesheet entries"
  end
end
