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

      run_live_handoff(:re_cutover, company_ids:)

      expect([by_id.call(entry_id), by_values.call]).to eq([1, 1])
      drained = timekeeping.exec_params("SELECT project_id, user_id FROM entries WHERE id = $1", [entry_id]).first
      expect(drained.fetch("project_id").to_i).to eq(project.id)
      expect(drained.fetch("user_id").to_i).to eq(owner.id)
    end
  ensure
    timekeeping&.close
  end
end

RSpec.describe "Live handoff sequence", :integrated_runtime, :two_tenant_seed, committed_data: true,
                                        owner_state: "legacy" do
  include LiveHandoff::ExampleHelpers

  it "run_live_handoff moves the owner, raises the generation, clears handoff_step and returns a clean report for both seeded companies on cutover, rollback and re-cutover" do
    company_ids = [fork_and_leaf.id, copper_kettle.id]
    read_row = lambda do
      TimekeepingOwnership.uncached do
        TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID).pick(:owner, :generation, :handoff_step)
      end
    end

    with_live_handoff_integrations(@integrated_runtime) do
      [[:cutover, "timekeeping"], [:rollback, "monolith"], [:re_cutover, "timekeeping"]].each do |direction, new_owner|
        _, generation_before, = read_row.call

        report = run_live_handoff(direction, company_ids:)

        owner, generation, handoff_step = read_row.call
        # "After each run, assert the new owner, a risen generation and `handoff_step` nil."
        expect(owner).to eq(new_owner)
        expect(generation).to be > generation_before
        expect(handoff_step).to be_nil
        # "Then read `generation-<n>/reconciliation.json` and require exactly both seeded company ids, each with `abort` false and `unlisted` empty, and `unassigned` empty."
        expect(report.fetch("companies").keys.map { |id| Integer(id) }).to match_array(company_ids)
        report.fetch("companies").each_value do |company|
          expect(company.fetch("abort")).to be(false)
          expect(company.fetch("unlisted")).to eq([])
        end
        expect(report.fetch("unassigned")).to eq([])
        expect(LiveHandoff.reconciliation_failures(report, company_ids:)).to eq([])
      end
    end
  end
end

RSpec.describe "Timekeeping handoff sequence", :integrated_runtime, :two_tenant_seed, committed_data: true, owner_state: "legacy" do
  include LiveHandoff::ExampleHelpers

  # "Assert that Timekeeping has no row for the entry before re-cutover, and exactly one row with the written values after it."
  it "a web create after rollback is absent from Timekeeping until re-cutover and then present exactly once" do
    company_ids = [fork_and_leaf.id, copper_kettle.id].sort
    owner = User.with_role(:owner, copper_kettle).first
    project = copper_kettle.projects.kept.first
    note = "post-rollback write #{SecureRandom.hex(4)}"
    url = ENV.fetch(TimekeepingDatabaseReset::DATABASE_URL_KEY)
    TestDatabaseGuard.require_test_database_url!(url)
    count_timekeeping = lambda do |sql, params|
      connection = TimekeepingDatabaseReset.connect(url, TimekeepingDatabaseReset.database_name(url))
      Integer(connection.exec_params(sql, params).getvalue(0, 0))
    ensure
      connection&.close
    end

    with_live_handoff_integrations(@integrated_runtime) do
      run_live_handoff(:cutover, company_ids:)
      run_live_handoff(:rollback, company_ids:)

      reply = LiveHandoff.send_request(@integrated_runtime.monolith_url, {
        method: "POST", path: "/api/v1/timesheet_entry",
        headers: { "Content-Type" => "application/json", "X-Auth-Email" => owner.email, "X-Auth-Token" => owner.token },
        body: { "project_id" => project.id, "timesheet_entry" => {
          "project_id" => project.id, "duration" => 37, "work_date" => Date.current.iso8601, "note" => note, "bill_status" => "unbilled"
        } }
      })
      expect(reply.status).to eq(200)
      entry_id = JSON.parse(reply.body).dig("entry", "id")

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      deadline = started + 60
      projected = nil
      until projected
        projected = ActiveRecord::Base.uncached do
          ActiveRecord::Base.connection.select_rows(
            "SELECT duration, note FROM timesheet_entries WHERE id = $1 AND company_id = $2", "poll", [entry_id, copper_kettle.id]
          ).first
        end
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if projected.nil? && now > deadline
          raise "entry #{entry_id} did not reach the projection within 60 s (waited #{(now - started).round} s)"
        end

        sleep 1 unless projected
      end
      expect(projected).to eq([37.0, note])

      by_id = "SELECT count(*) FROM entries WHERE id = $1 AND company_id = $2"
      by_values = "SELECT count(*) FROM entries WHERE company_id = $1 AND note = $2 AND duration = 37"
      expect(count_timekeeping.call(by_id, [entry_id, copper_kettle.id])).to eq(0)
      expect(count_timekeeping.call(by_values, [copper_kettle.id, note])).to eq(0)

      run_live_handoff(:re_cutover, company_ids:)

      expect(count_timekeeping.call(by_id, [entry_id, copper_kettle.id])).to eq(1)
      expect(count_timekeeping.call(by_values, [copper_kettle.id, note])).to eq(1)
    end
  end
end
