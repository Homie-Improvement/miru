# frozen_string_literal: true

require "rails_helper"
require "json"
require "net/http"

# Section 12.4 of docs/architecture/timekeeping-soa.md, "Relay paused", run
# against the live demo runtime on both seeded companies. It needs
# TIMEKEEPING_LIVE=1, so the default suite skips it, and the CI live job does
# not run it.
#
# Each example cuts over from the legacy owner state for real, drives the relay
# to a delivered baseline, then pauses it, so the entry created next can only
# reach the monolith projection once the relay resumes.
RSpec.describe "Timekeeping relay paused", :integrated_runtime, :two_tenant_seed,
               committed_data: true, owner_state: "legacy" do
  include_context "timekeeping live handoff"

  # The draft invoice save reads the projection through
  # InvoiceLineItem#timesheet_entry_found_in_invoice_company, and the database
  # refuses a line item whose entry is not in timesheet_entries. Both hold
  # until the follow-up invoice change lands, so that part is pending, and
  # RSpec fails the example once it passes.
  def relay_paused_ac5_pending_reason
    "AC5 waits on the follow-up invoice change: the draft invoice save answers 422 " \
      "\"Invoice line items timesheet entry not found\" because the projection-backed " \
      "validation InvoiceLineItem#timesheet_entry_found_in_invoice_company reads " \
      "timesheet_entries, and the keys invoice_line_items → timesheet_entries and " \
      "invoice_line_item_time_entries → timesheet_entries refuse the row before the " \
      "relay delivers it"
  end

  before { WebMock.disable_net_connect!(allow_localhost: true) }

  # An owner or admin of the company who can sign requests with the legacy
  # X-Auth-Email and X-Auth-Token headers.
  def relay_paused_admin(company)
    company.users.order(:id).find do |user|
      user.token.present? && user.current_workspace_id == company.id && user.employed_at?(company.id) &&
        (user.has_role?(:owner, company) || user.has_role?(:admin, company))
    end || raise("#{company.name} has no seeded owner or admin with an API token")
  end

  def relay_paused_project(company)
    Project.kept.joins(:client).where(clients: { company_id: company.id }, billable: true).order(:id).first ||
      raise("#{company.name} has no seeded billable project")
  end

  def relay_paused_request(method, path, user:, body: nil)
    uri = URI.join(@integrated_runtime.monolith_url, path)
    request = { get: Net::HTTP::Get, post: Net::HTTP::Post }.fetch(method).new(uri)
    request["X-Auth-Email"] = user.email
    request["X-Auth-Token"] = user.token
    request["Accept"] = "application/json"
    if body
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body)
    end
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
  end

  # Creates the entry through the monolith, which forwards it to Timekeeping
  # after the cutover, and returns the id the response names.
  def relay_paused_create_entry(user:, project:)
    response = relay_paused_request(
      :post, "/api/v1/timesheet_entry", user:,
      body: {
        project_id: project.id,
        timesheet_entry: { duration: 60, work_date: Date.current.iso8601, note: "Relay paused", bill_status: "unbilled" }
      }
    )
    expect(response.code).to eq("200"), "entry create answered #{response.code}: #{response.body}"
    Integer(JSON.parse(response.body).dig("entry", "id"))
  end

  def relay_paused_listed_entry_ids(user:)
    response = relay_paused_request(:get, "/api/v1/timesheet_entry", user:)
    expect(response.code).to eq("200"), "entry list answered #{response.code}: #{response.body}"
    JSON.parse(response.body).fetch("entries").values.flatten.filter_map { |entry| entry["id"] }
  end

  # The entry's outbox snapshots in Timekeeping, as [[outbox_position, sent?], ...].
  def relay_paused_outbox_rows(company_id:, entry_id:)
    TimekeepingLiveHandoff.with_timekeeping_database do |connection|
      connection.exec_params(
        "SELECT outbox_position, sent_at IS NOT NULL FROM outbox_snapshots " \
        "WHERE company_id = $1 AND id = $2 ORDER BY outbox_position",
        [company_id, entry_id]
      ).values.map { |position, sent| [Integer(position), sent == "t"] }
    end
  end

  # The monolith projection row of the entry, read uncached because the
  # runtime's relay writes it through another connection.
  def relay_paused_projection_row(company_id:, entry_id:)
    ActiveRecord::Base.uncached do
      ActiveRecord::Base.connection.select_all(
        "SELECT id, locked FROM timesheet_entries WHERE company_id = $1 AND id = $2",
        "relay paused projection", [company_id, entry_id]
      ).first
    end
  end

  # Cuts over, delivers everything already in the outbox, then pauses the
  # relay, so nothing created afterwards can reach the projection.
  def relay_paused_baseline!
    live_handoff_cutover!
    live_handoff_catch_up!
    live_handoff_pause_relay
  end

  def relay_paused_expect_queued_only(company:, entry_id:)
    outbox_rows = relay_paused_outbox_rows(company_id: company.id, entry_id:)
    expect(outbox_rows).not_to be_empty, "Timekeeping wrote no outbox snapshot for entry #{entry_id}"
    expect(outbox_rows.map(&:last)).to all(be(false))
    expect(TimekeepingLiveHandoff.with_timekeeping_database do |connection|
      TimekeepingLiveHandoff.queued_count(connection, company_id: company.id, entry_id:)
    end).to eq(outbox_rows.size)
    expect(relay_paused_projection_row(company_id: company.id, entry_id:)).to be_nil
    outbox_rows
  end

  %i[fork_and_leaf copper_kettle].each do |company_name|
    context "for #{company_name}" do
      let(:company) { public_send(company_name) }
      let(:admin) { relay_paused_admin(company) }
      let(:project) { relay_paused_project(company) }

      it "a queued entry reaches the projection once the relay resumes" do
        with_live_handoff do
          relay_paused_baseline!

          entry_id = relay_paused_create_entry(user: admin, project:)
          outbox_rows = relay_paused_expect_queued_only(company:, entry_id:)

          live_handoff_resume_relay
          # Read after the entry exists, so catching up must deliver its snapshot.
          through = Timekeeping::Handoff::TimekeepingStore.new.highest_outbox_position
          expect(outbox_rows.map(&:first).max).to be <= through
          live_handoff_catch_up!(through:)

          expect(relay_paused_projection_row(company_id: company.id, entry_id:)).not_to be_nil
          # The same rows queued before resume, each now sent, not removed.
          expect(relay_paused_outbox_rows(company_id: company.id, entry_id:))
            .to eq(outbox_rows.map { |position, _sent| [position, true] })
        end
      end

      it "invoicing with the relay paused (AC5)" do
        with_live_handoff do
          relay_paused_baseline!

          entry_id = relay_paused_create_entry(user: admin, project:)
          # Design AC5: the entry is listed while the relay is paused, and only
          # the projection lags.
          relay_paused_expect_queued_only(company:, entry_id:)
          expect(relay_paused_listed_entry_ids(user: admin)).to include(entry_id)

          pending relay_paused_ac5_pending_reason

          response = relay_paused_request(
            :post, "/api/v1/invoices", user: admin,
            body: {
              invoice: {
                client_id: project.client_id,
                invoice_number: "LIVE-AC5-#{entry_id}",
                issue_date: Date.current.iso8601,
                due_date: 30.days.from_now.to_date.iso8601,
                status: "draft",
                currency: company.base_currency,
                invoice_line_items_attributes: [
                  { name: "Relay paused", description: "AC5", date: Date.current.iso8601, rate: 100, quantity: 60,
                    timesheet_entry_id: entry_id }
                ]
              }
            }
          )
          expect(response.code).to eq("200"), "draft invoice save answered #{response.code}: #{response.body}"

          live_handoff_resume_relay
          live_handoff_catch_up!

          expect(relay_paused_projection_row(company_id: company.id, entry_id:)).to include("locked" => true)
        end
      end
    end
  end
end
