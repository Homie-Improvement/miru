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

  # Runs the handoff runner and reports a refusal as a failed task, so a
  # stopped handoff never looks finished to the operator's shell.
  def run_timekeeping_handoff(**arguments)
    Timekeeping::Handoff::Runner.run(**arguments)
    puts "Timekeeping handoff #{arguments.fetch(:direction)}#{' abort' if arguments[:abort]} finished"
  rescue Timekeeping::Handoff::Runner::Refused, Timekeeping::Handoff::Store::Error => error
    abort error.message
  end

  # The direction a resume or abort continues, from DIRECTION.
  def timekeeping_handoff_direction
    direction = ENV["DIRECTION"].to_s
    return direction.to_sym if Timekeeping::Handoff::Steps::DIRECTIONS.key?(direction.to_sym)

    abort "Set DIRECTION to one of #{Timekeeping::Handoff::Steps::DIRECTIONS.keys.join(', ')}."
  end

  # The forward tasks only start a handoff. Continuing one, or re-sending the
  # admit call after a flip, is what handoff_resume is for, so a repeated
  # forward task is refused instead of reporting a handoff it did not run.
  desc "Hand timesheet entries from the monolith's legacy table to Timekeeping (first cutover)"
  task handoff_cutover: :environment do
    run_timekeeping_handoff(direction: :cutover, resume: false)
  end

  desc "Hand timesheet entries from Timekeeping back to the monolith"
  task handoff_rollback: :environment do
    run_timekeeping_handoff(direction: :rollback, resume: false)
  end

  desc "Hand timesheet entries from the monolith's prepared tables to Timekeeping again"
  task handoff_re_cutover: :environment do
    run_timekeeping_handoff(direction: :re_cutover, resume: false)
  end

  desc "Resume the Timekeeping handoff in progress (DIRECTION=cutover|rollback|re_cutover required; " \
       "needs the storage/timekeeping_handoff files the earlier run wrote)"
  task handoff_resume: :environment do
    run_timekeeping_handoff(direction: timekeeping_handoff_direction, resume: true)
  end

  desc "Abort the Timekeeping handoff in progress (DIRECTION=cutover|rollback|re_cutover required)"
  task handoff_abort: :environment do
    run_timekeeping_handoff(direction: timekeeping_handoff_direction, abort: true)
  end
end
