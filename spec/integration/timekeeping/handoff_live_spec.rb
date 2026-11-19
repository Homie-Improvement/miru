# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "json"
require "pg"
require "tmpdir"

# Runs the real handoff with the owners config/initializers/timekeeping_handoff.rb
# configures, against the monolith's test database and a real Timekeeping
# server and database. It needs TIMEKEEPING_LIVE=1 and TIMEKEEPING_DATABASE_URL,
# so the default suite skips it. The three runs share one example: a seeded
# committed example reloads the seed before it runs, so separate examples
# would hide what cutover leaves for rollback.
RSpec.describe Timekeeping::Handoff::Runner, :two_tenant_seed, committed_data: true do
  handoff_live_tables = %w[idempotency_receipts audit_events reservations invoice_operations outbox_snapshots entries].freeze

  before(:all) do
    skip "Set TIMEKEEPING_LIVE=1 to run the handoff against a real Timekeeping server" unless ENV["TIMEKEEPING_LIVE"] == "1"

    # The live instance runs db:prepare on this URL and the after hook empties
    # its tables, so refuse any database that is not a test database first.
    IntegratedRuntime.require_test_database_url!(ENV.fetch("TIMEKEEPING_DATABASE_URL"))
    WebMock.disable_net_connect!(allow_localhost: true)
    @handoff_live_reference = TimekeepingLiveInstance::ReferenceStub.new
    @handoff_live_timekeeping = TimekeepingLiveInstance.start(
      reference_stub: @handoff_live_reference, snapshot_app: Rails.application
    )
    @handoff_live_reference.service_token = @handoff_live_timekeeping.service_token
  end

  after(:all) { @handoff_live_timekeeping&.stop }

  after do
    # A skipped example started nothing, and may run without a Timekeeping database.
    next unless ENV["TIMEKEEPING_LIVE"] == "1"

    # This hook also runs when before(:all) refused the database, so it checks again.
    timekeeping_url = ENV.fetch("TIMEKEEPING_DATABASE_URL")
    IntegratedRuntime.require_test_database_url!(timekeeping_url)
    timekeeping = PG.connect(timekeeping_url)
    timekeeping.exec("TRUNCATE #{handoff_live_tables.join(', ')} CASCADE")
  ensure
    timekeeping&.close
  end

  # Reruns the initializer's own code, so the integrations it builds read the
  # live server's URL and token from ENV. Every other to_prepare hook is left
  # alone: rerunning them all reloads FactoryBot, which fails on the seed's
  # top-level helper methods.
  def handoff_live_rebuild_integrations
    allow(Rails.application.config).to receive(:to_prepare).and_yield
    load Rails.root.join("config/initializers/timekeeping_handoff.rb").to_s
  end

  def handoff_live_stored_row
    TimekeepingOwnership.uncached do
      TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID).pick(:owner, :generation, :handoff_step)
    end
  end

  def handoff_live_entry_times(entry_id)
    ActiveRecord::Base.connection.select_rows(
      "SELECT created_at, updated_at FROM timesheet_entries WHERE id = #{Integer(entry_id)}"
    ).first
  end

  it "runs cutover, rollback and re-cutover with the configured owners to the flip against both real databases" do
    entry_id = ActiveRecord::Base.connection.select_value("SELECT id FROM timesheet_entries ORDER BY id LIMIT 1")
    times_before = handoff_live_entry_times(entry_id)
    live_env = {
      Timekeeping::EntryApiClient::BASE_URL_ENV => @handoff_live_timekeeping.base_url,
      Internal::V1::BaseController::SERVICE_TOKEN_ENV => @handoff_live_timekeeping.service_token
    }

    with_timekeeping_env(live_env) do
      handoff_live_rebuild_integrations

      [[:cutover, "timekeeping"], [:rollback, "monolith"], [:re_cutover, "timekeeping"]].each do |direction, new_owner|
        owner_before, generation_before, = handoff_live_stored_row
        report_root = Pathname(Dir.mktmpdir("timekeeping-handoff-live"))

        # No owners: argument, so the run uses Runner.configured_owners.
        described_class.run(direction:, report_root:)

        owner, generation, handoff_step = handoff_live_stored_row
        # "After each run it asserts the stored state: the owner changed, the generation rose, and `handoff_step` is NULL."
        expect(owner).to eq(new_owner)
        expect(owner).not_to eq(owner_before)
        expect(generation).to be > generation_before
        expect(handoff_step).to be_nil
        reconciliation = JSON.parse(File.read(report_root.join("generation-#{generation}", "reconciliation.json")))
        expect(reconciliation.fetch("abort")).to be(false)

        # Rollback drains Timekeeping's correction snapshots into the projection;
        # the entry keeps the timestamps it had before cutover, to the microsecond.
        expect(handoff_live_entry_times(entry_id)).to eq(times_before) if direction == :rollback
      ensure
        FileUtils.rm_rf(report_root) if report_root
      end
    end
  ensure
    # ENV is restored by now, so the configured integrations go back to it.
    handoff_live_rebuild_integrations if ENV["TIMEKEEPING_LIVE"] == "1"
  end
end
