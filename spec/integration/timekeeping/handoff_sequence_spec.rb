# frozen_string_literal: true

require "rails_helper"
require "json"
require "securerandom"

# Runs real handoffs against the whole local runtime, so a write accepted by
# the monolith after a rollback is shown to reach the projection and then to
# be drained into Timekeeping at re-cutover exactly once. Needs
# TIMEKEEPING_LIVE=1 and TIMEKEEPING_DATABASE_URL; the default suite skips it.
RSpec.describe "Timekeeping handoff sequence", :integrated_runtime, :two_tenant_seed, committed_data: true, owner_state: "legacy" do
  it "drains a web entry written after rollback into Timekeeping at re-cutover as exactly one row" do
    company_ids = [fork_and_leaf.id, copper_kettle.id]
    owner = User.with_role(:owner, copper_kettle).first
    project = copper_kettle.projects.kept.first
    note = "post-rollback write #{SecureRandom.hex(4)}"
    duration = 47.0
    work_date = "2026-01-07"
    url = ENV.fetch(TimekeepingDatabaseReset::DATABASE_URL_KEY)
    TestDatabaseGuard.require_test_database_url!(url)
    timekeeping = TimekeepingDatabaseReset.connect(url, TimekeepingDatabaseReset.database_name(url))
    by_id = lambda do |id|
      timekeeping.exec_params("SELECT count(*) FROM entries WHERE id = $1 AND company_id = $2", [id, copper_kettle.id])
                 .getvalue(0, 0).to_i
    end
    by_values = lambda do
      timekeeping.exec_params(
        "SELECT count(*) FROM entries WHERE company_id = $1 AND note = $2 AND duration = $3 AND work_date = $4",
        [copper_kettle.id, note, duration, work_date]
      ).getvalue(0, 0).to_i
    end

    with_live_handoff_integrations(@integrated_runtime) do
      # run_live_handoff asserts the new owner, the risen generation, a nil
      # handoff_step and a clean reconciliation report after each run.
      run_live_handoff(:cutover, company_ids:)
      run_live_handoff(:rollback, company_ids:)

      reply = LiveHandoff.send_request(@integrated_runtime.monolith_url, {
        method: "POST", path: "/api/v1/timesheet_entry",
        headers: { "X-Auth-Email" => owner.email, "X-Auth-Token" => owner.token, "Content-Type" => "application/json" },
        body: { "project_id" => project.id,
                "timesheet_entry" => { "duration" => duration, "note" => note, "work_date" => work_date } }
      })
      expect(reply.status).to eq(200)
      entry_id = JSON.parse(reply.body).fetch("entry").fetch("id")

      # "Check the row's values in the projection after rollback, and in Timekeeping after re-cutover, with exactly one row."
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      deadline = started + 60
      row = nil
      loop do
        row = ActiveRecord::Base.uncached do
          ActiveRecord::Base.connection.select_one(
            "SELECT note, duration, work_date, project_id FROM timesheet_entries WHERE id = $1 AND company_id = $2",
            "projection", [entry_id, copper_kettle.id]
          )
        end
        break if row

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise "entry #{entry_id} did not reach the projection within 60 s (waited #{(now - started).round} s)" if now > deadline

        sleep 1
      end
      expect(row.slice("note", "duration", "project_id")).to eq("note" => note, "duration" => duration, "project_id" => project.id)
      expect(row.fetch("work_date").to_s).to eq(work_date)

      # "Assert that Timekeeping has no row for the entry before re-cutover, and exactly one row with the written values after it."
      expect([by_id.call(entry_id), by_values.call]).to eq([0, 0])

      report = run_live_handoff(:re_cutover, company_ids:)

      expect(report.fetch("companies").keys.map { |id| Integer(id) }).to match_array(company_ids)
      expect([by_id.call(entry_id), by_values.call]).to eq([1, 1])
      drained = timekeeping.exec_params("SELECT project_id, user_id FROM entries WHERE id = $1", [entry_id]).first
      expect(drained.fetch("project_id").to_i).to eq(project.id)
      expect(drained.fetch("user_id").to_i).to eq(owner.id)
    end
  ensure
    timekeeping&.close
  end
end
