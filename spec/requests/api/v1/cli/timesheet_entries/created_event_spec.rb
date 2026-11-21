# frozen_string_literal: true

require "rails_helper"

# Proves that a CLI create raises one TimesheetEntries::Created in every
# ownership state, and that neither a retry answered from a stored receipt nor
# the relay's later snapshot delivery to the projection raises another.
RSpec.describe "Api::V1::Cli::TimesheetEntries#create TimesheetEntries::Created event", type: :request do
  let(:company) { create(:company, plan_tier: "free") }
  let(:user) { create(:user, current_workspace_id: company.id) }
  let(:project) { create(:project, billable: true, client: create(:client, company:)) }
  let(:cli_token) { CliSession.issue_for(user:, company:).last }
  let(:created_event_params) do
    { timesheet_entry: { project_id: project.id, duration_minutes: 30, work_date: Date.current.iso8601 } }
  end

  before do
    create(:employment, company:, user:)
    user.add_role :employee, company
    create(:project_member, project:, user:)
  end

  # committed_data, so a live Timekeeping app in a regression run can read the
  # company, user and project the request names.
  context "when Timekeeping owns the entries", :forwards_to_timekeeping, committed_data: true do
    let(:fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

    around { |example| with_forwarded_timekeeping_env { example.run } }

    before { arrange_forwarded_timekeeping(fake, company:, users: { user => "employee" }, project:) }

    it "raises exactly one TimesheetEntries::Created with the CLI user and source when the same forwarded CLI create is sent twice under one Idempotency-Key" do
      headers = cli_auth_headers(cli_token).merge("Idempotency-Key" => "cli-created-event-retry-#{SecureRandom.uuid}")
      first_id = nil

      events = timesheet_entries_created_events do
        send_request :post, api_v1_cli_timesheet_entries_path, params: created_event_params, headers: headers
        expect(response).to have_http_status(:ok)
        first_id = json_response.dig("entry", "id")
        send_request :post, api_v1_cli_timesheet_entries_path, params: created_event_params, headers: headers
        expect(response).to have_http_status(:ok)
        expect(json_response.dig("entry", "id")).to eq(first_id)
      end

      # "A time entry create forwarded to Timekeeping raises exactly one `TimesheetEntries::Created` event, with the same actor and data shape as a create in the legacy state, once Timekeeping answers the create with success"
      # "A forwarded create that Timekeeping refuses, or that is replayed from a stored idempotency receipt, raises no event"
      expect(events.size).to eq(1)
      event = events.first
      expect(event[:context]).to include(source: "cli")
      payload = event[:payload].to_h
      expect(payload[:actor]).to eq(id: user.id, type: "User")
      expect(payload[:data].keys).to contain_exactly(:timesheet_entry_id, :project_id, :user_id, :duration)
      expect(payload[:data]).to include(timesheet_entry_id: first_id, project_id: project.id, user_id: user.id)
    end

    it "raises no further TimesheetEntries::Created when the forwarded entry's snapshot reaches the projection" do
      created = timesheet_entries_created_events do
        send_request :post, api_v1_cli_timesheet_entries_path, params: created_event_params,
                                                               headers: cli_auth_headers(cli_token)
      end
      expect(response).to have_http_status(:ok)
      entry_id = json_response.dig("entry", "id")
      snapshot = TimekeepingSnapshots.entry(id: entry_id, company_id: company.id, version: 1,
                                            project_id: project.id, user_id: user.id)
      batch = TimekeepingSnapshots.batch(
        TimekeepingSnapshots.item(snapshot, generation: TimekeepingOwnership.current.generation)
      )

      delivered = timesheet_entries_created_events do
        result = Timekeeping::ProjectionConsumer.call(batch:, idempotency_key: "created-event-snapshot-#{entry_id}")
        expect(result.status).to eq(200)
      end

      # "No event is raised twice for one create when the relay later delivers that entry's snapshot to the projection"
      expect(TimesheetEntry.where(id: entry_id)).to exist
      expect(created.size).to eq(1)
      expect(delivered).to be_empty
    end
  end

  it "raises exactly one TimesheetEntries::Created for a rollback-state CLI create across the create and the relay to the projection", committed_data: true, owner_state: "rollback" do
    expect_owner_state!("rollback")
    events = timesheet_entries_created_events do
      send_request :post, api_v1_cli_timesheet_entries_path, params: created_event_params,
                                                             headers: cli_auth_headers(cli_token)
      expect(response).to have_http_status(:ok)
      relay_local_entries_to_projection(company)
    end

    entry_id = json_response.dig("entry", "id")
    # "No event is raised twice for one create when the relay later delivers that entry's snapshot to the projection"
    expect(TimesheetEntry.where(id: entry_id)).to exist
    expect(events.size).to eq(1)
    payload = events.first[:payload].to_h
    expect(payload[:actor]).to eq(id: user.id, type: "User")
    expect(payload[:data]).to include(timesheet_entry_id: entry_id, project_id: project.id, user_id: user.id)
  end

  it "raises exactly one TimesheetEntries::Created when a rollback-state CLI create is retried under one Idempotency-Key and relayed", committed_data: true, owner_state: "rollback" do
    headers = cli_auth_headers(cli_token).merge("Idempotency-Key" => "cli-rollback-retry-#{SecureRandom.uuid}")
    first_id = nil

    expect_owner_state!("rollback")
    events = timesheet_entries_created_events do
      send_request :post, api_v1_cli_timesheet_entries_path, params: created_event_params, headers: headers
      expect(response).to have_http_status(:ok)
      first_id = json_response.dig("entry", "id")
      send_request :post, api_v1_cli_timesheet_entries_path, params: created_event_params, headers: headers
      expect(response).to have_http_status(:ok)
      expect(json_response.dig("entry", "id")).to eq(first_id)
      relay_local_entries_to_projection(company)
    end

    # The retry is answered from the prepared store's receipt, so only the first attempt raises the event.
    expect(TimesheetEntry.where(id: first_id)).to exist
    expect(events.map { |event| event[:payload].to_h.dig(:data, :timesheet_entry_id) }).to eq([first_id])
  end

  # Rollback writes the prepared store, where no TimesheetEntry is saved, so
  # before this change no event was raised here.
  it "tags a rollback-state CLI create event with the CLI user and source", owner_state: "rollback" do
    expect_owner_state!("rollback")

    # "A create in the legacy and rollback states raises the event exactly as today (one event, from the model)"
    event = assert_event_reported("TimesheetEntries::Created") do
      send_request :post, api_v1_cli_timesheet_entries_path, params: created_event_params,
                                                             headers: cli_auth_headers(cli_token)
    end

    expect(response).to have_http_status(:ok)
    expect(event[:context]).to include(source: "cli")
    expect(event[:payload].to_h[:actor]).to eq(id: user.id, type: "User")
  end

  it "raises exactly one TimesheetEntries::Created with the CLI user and source for a legacy-state CLI create", owner_state: "legacy" do
    expect_owner_state!("legacy")
    events = timesheet_entries_created_events do
      send_request :post, api_v1_cli_timesheet_entries_path, params: created_event_params,
                                                             headers: cli_auth_headers(cli_token)
    end

    expect(response).to have_http_status(:ok)
    # "A create in the legacy and rollback states raises the event exactly as today (one event, from the model)"
    expect(events.size).to eq(1)
    event = events.first
    expect(event[:context]).to include(source: "cli")
    expect(event[:payload].to_h[:actor]).to eq(id: user.id, type: "User")
    expect(event[:payload].to_h[:data]).to include(timesheet_entry_id: json_response.dig("entry", "id"))
    expect(event[:payload].to_h[:data].keys).to contain_exactly(:timesheet_entry_id, :project_id, :user_id, :duration)
  end
end
