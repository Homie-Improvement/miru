# frozen_string_literal: true

require "securerandom"
require "uri"

# Request helpers for the Timekeeping shared contract examples. They reach an
# implementation only through the timekeeping_client and timekeeping_arrange
# lets, so the same examples run against the fakes and the real providers.
module TimekeepingContractExampleHelpers
  # An id no implementation hands out, used as "a missing id".
  MISSING_ID = 999_999_999

  def timekeeping_request(method, path, headers: {}, body: nil)
    timekeeping_client.call(method, path, headers:, body:)
  end

  # The path of a contract route with its {placeholders} filled in.
  def timekeeping_path(contract_name, route, **params)
    TimekeepingContract.load(contract_name).dig("routes", route.to_s, "path")
      .gsub(/\{(\w+)\}/) { params.fetch(Regexp.last_match(1).to_sym) }
  end

  def timekeeping_contract_error(contract_name, name)
    TimekeepingContract.load(contract_name).dig("errors", name)
  end

  # Every state-changing request carries an Idempotency-Key (section 5.1), so
  # each request gets a fresh one unless an example replays a key on purpose.
  def user_headers(token, generation: timekeeping_arrange.current_generation, key: new_key)
    headers = { "Authorization" => "Bearer #{token}", "Ownership-Generation" => generation.to_s }
    key ? headers.merge("Idempotency-Key" => key) : headers
  end

  def bearer_headers(credential, key: nil)
    headers = credential ? { "Authorization" => "Bearer #{credential}" } : {}
    key ? headers.merge("Idempotency-Key" => key) : headers
  end

  def new_key
    SecureRandom.uuid
  end

  def entry_body(project:, **overrides)
    {
      "project_id" => project, "work_date" => "2026-03-02", "duration" => 90.0, "note" => "Design review",
      "source" => "manual", "source_metadata" => {}
    }.merge(overrides.transform_keys(&:to_s))
  end

  def create_entry(company, token, body, key: new_key)
    timekeeping_request("POST", timekeeping_path(:entry_api, :create, company_id: company), headers: user_headers(token, key:), body:)
  end

  def show_entry(company, token, entry_id)
    timekeeping_request("GET", timekeeping_path(:entry_api, :show, company_id: company, entry_id:), headers: user_headers(token))
  end

  def list_entries(company, token, **query)
    path = timekeeping_path(:entry_api, :index, company_id: company)
    path = "#{path}?#{URI.encode_www_form(query)}" unless query.empty?
    timekeeping_request("GET", path, headers: user_headers(token))
  end

  # Reservation routes take the generation in the body.
  def reservation_command(route, company, credential, body, **path_params)
    timekeeping_request("POST", timekeeping_path(:reservations, route, company_id: company, **path_params),
                        headers: bearer_headers(credential),
                        body: { "generation" => timekeeping_arrange.current_generation }.merge(body))
  end

  def reservation_operations
    TimekeepingContract.load(:reservations).fetch("routes").keys
  end

  def deliver_snapshots(credential, snapshots, key: new_key)
    contract = TimekeepingContract.load(:entry_snapshots)
    timekeeping_request("POST", timekeeping_path(:entry_snapshots, :deliver), headers: bearer_headers(credential, key:),
                                                                              body: { "schema_version" => contract.fetch("schema_version"), "snapshots" => snapshots })
  end

  # One snapshot item holding every contract entry field. Its project and user
  # are arranged in the snapshot's company, so a projection that keeps
  # foreign keys to them can store the row.
  def snapshot_item(entry_id:, company:, version:, generation: timekeeping_arrange.current_generation, outbox_position: version,
                    project: timekeeping_arrange.project(company:), user: timekeeping_arrange.user(company:, role: "employee"), **fields)
    entry = TimekeepingContract.load(:entry_snapshots).fetch("entry_fields").index_with(nil).merge(
      "id" => entry_id, "company_id" => company, "version" => version, "project_id" => project, "user_id" => user,
      "work_date" => "2026-03-02", "duration" => 90.0, "note" => "v#{version}", "bill_status" => "unbilled",
      "review_status" => "not_required", "locked" => false, "source" => "manual", "source_metadata" => {},
      "proof_metadata" => {}, "created_at" => "2026-03-02T09:00:00Z", "updated_at" => "2026-03-02T09:00:00Z"
    ).merge(fields.transform_keys(&:to_s))
    { "generation" => generation, "outbox_position" => outbox_position, "entry" => entry }
  end
end
