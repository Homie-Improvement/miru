# frozen_string_literal: true

namespace :timekeeping do
  desc "Set timesheet_entries.company_id from project -> client -> company where it is missing or wrong"
  task backfill_entry_company_ids: :environment do
    fixed = Timekeeping::EntryCompanyBackfill.call(ActiveRecord::Base.connection)

    puts "fixed company_id on #{fixed} timesheet entries"
  end

  desc "Load the demo seed into an empty database and record its seed disposition (MIRU_SEED_AS_OF required, OUTPUT optional)"
  task record_seed_disposition: :environment do
    abort "Refusing to record the seed disposition in production." if Rails.env.production?

    as_of = ENV["MIRU_SEED_AS_OF"].presence
    abort "Set MIRU_SEED_AS_OF (for example 2026-10-23) so the seed and its recorded disposition are reproducible." unless as_of

    path = ENV["OUTPUT"].presence || Timekeeping::SeedDispositionRecorder::DEFAULT_PATH.to_s
    disposition = Timekeeping::SeedDispositionRecorder.generate!(path:, as_of:)
    invoice_count = disposition["companies"].values.sum(&:size)
    puts "recorded #{invoice_count} invoices with unlocked links to #{path}"
  rescue Timekeeping::SeedDispositionRecorder::Error => error
    abort error.message
  end
end
