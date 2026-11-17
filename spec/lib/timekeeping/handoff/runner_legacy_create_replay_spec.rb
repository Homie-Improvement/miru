# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# Each example commits rows over the shared seed and cuts ownership over, so
# each runs in a group of its own (spec/support/database_cleaner.rb).
module LegacyCreateReplayAfterCutoverSpecSupport
  def legacy_replay_seeded_actor
    company = Company.order(:id).find { |candidate| candidate.projects.where(billable: true).exists? }
    project = company.projects.where(billable: true).order(:id).first
    user = company.users.order(:id).find { |member| member.has_role?(:owner, company) || member.has_role?(:admin, company) }
    [company, project, user]
  end

  def legacy_replay_create(company:, project:, user:, key:, attributes:, actor_kind: "user")
    context = Timekeeping::WriteContext.new(company:, actor: user, actor_kind:, request_id: SecureRandom.uuid,
                                            idempotency_key: key)
    Timekeeping::Gateway.new(context:).create(user:, project:, attributes:)
  end

  def legacy_replay_cutover
    TimekeepingHandoffFakes::InMemoryTimekeepingStore.new.tap do |timekeeping|
      Timekeeping::Handoff::Runner.run(direction: :cutover, owners: TimekeepingHandoffFakes.owners(timekeeping:),
                          report_root: Dir.mktmpdir("handoff-report"))
    end
  end

  # Answers a forwarded create as Timekeeping's EntryWriter does: from a stored
  # receipt with the same company, user actor, operation and key when the
  # SHA-256 of the regenerated JSON body matches, 422 when it does not, and
  # otherwise by recording a new entry, which is returned in the array.
  def stub_legacy_replay_timekeeping(timekeeping, actor_id:)
    recorded = []
    stub_request(:post, %r{\Ahttp://timekeeping\.test/v1/companies/\d+/entries\z}).to_return do |request|
      company_id = Integer(request.uri.path[%r{/companies/(\d+)/}, 1], 10)
      key = request.headers.find { |name, _value| name.to_s.casecmp?("Idempotency-Key") }&.last
      body = JSON.parse(request.body)
      fingerprint = Digest::SHA256.hexdigest(JSON.generate(body))
      receipt = timekeeping.rows.fetch("idempotency_records").find do |row|
        row["company_id"] == company_id && row["actor_type"] == "user" && row["actor_id"] == actor_id &&
          row["operation"] == "create " && row["key"] == key
      end
      headers = { "Content-Type" => "application/json" }
      if receipt && receipt["fingerprint"] == fingerprint
        { status: receipt["status"], body: receipt["body"], headers: }
      elsif receipt
        { status: 422, body: JSON.generate("reason" => "idempotency_key_reused"), headers: }
      else
        recorded << body
        entry = body.slice("project_id", "user_id", "work_date", "duration", "note", "bill_status", "source", "source_metadata")
          .merge("id" => 9_000_000 + recorded.size, "company_id" => company_id, "version" => 1, "locked" => false)
        { status: 201, body: JSON.generate(entry), headers: }
      end
    end
    recorded
  end
end

RSpec.describe Timekeeping::Handoff::Runner, "legacy create replayed after the first cutover", :two_tenant_seed,
               :seeded_without_transaction do
  include LegacyCreateReplayAfterCutoverSpecSupport

  # "A create whose first attempt committed in the legacy store with an Idempotency-Key, retried with the same key and body after the first cutover flip, replays the original entry from Timekeeping, and the test shows no second entry was recorded."
  it "a keyed legacy create retried with the same key and body after the first cutover replays the original entry from Timekeeping and records no second entry" do
    company, project, user = legacy_replay_seeded_actor
    attributes = { duration: 45, work_date: Date.current, note: "Legacy timer before cutover", bill_status: "unbilled" }
    first = legacy_replay_create(company:, project:, user:, key: "legacy-cutover-replay-1", attributes:)
    expect(TimesheetEntry.unscoped.where(note: "Legacy timer before cutover").count).to eq(1)

    timekeeping = legacy_replay_cutover
    expect(TimekeepingOwnership.current).to have_attributes(owner: "timekeeping", handoff_step: nil)

    recorded = stub_legacy_replay_timekeeping(timekeeping, actor_id: user.id)
    retried = with_forwarded_timekeeping_env do
      legacy_replay_create(company:, project:, user:, key: "legacy-cutover-replay-1", attributes:)
    end

    expect(retried.id).to eq(first.id)
    expect(retried.note).to eq("Legacy timer before cutover")
    expect(recorded).to eq([])
    expect(TimesheetEntry.unscoped.where(note: "Legacy timer before cutover").count).to eq(1)
  end
end

RSpec.describe Timekeeping::Handoff::Runner, "legacy create replayed after a billing default change",
               :two_tenant_seed, :seeded_without_transaction do
  include LegacyCreateReplayAfterCutoverSpecSupport

  # The request body is unchanged; only the project's billing default, which the
  # forwarded body is filled from, changed between the attempts.
  it "a legacy create sent without bill_status still replays after cutover when its project became non-billable before the flip" do
    company, project, user = legacy_replay_seeded_actor
    attributes = { duration: 30, work_date: Date.current, note: "Billing default changed later" }
    first = legacy_replay_create(company:, project:, user:, key: "legacy-cutover-billing-1", attributes:)
    project.update_columns(billable: false)

    timekeeping = legacy_replay_cutover

    recorded = stub_legacy_replay_timekeeping(timekeeping, actor_id: user.id)
    retried = with_forwarded_timekeeping_env do
      legacy_replay_create(company:, project:, user:, key: "legacy-cutover-billing-1", attributes:)
    end

    expect(retried.id).to eq(first.id)
    expect(retried.note).to eq("Billing default changed later")
    expect(recorded).to eq([])
    expect(TimesheetEntry.unscoped.where(note: "Billing default changed later").count).to eq(1)
  end
end

RSpec.describe Timekeeping::Handoff::Runner, "legacy creates of two actor kinds replayed after the first cutover",
               :two_tenant_seed, :seeded_without_transaction do
  include LegacyCreateReplayAfterCutoverSpecSupport

  it "a browser create and a command-line create under one client key each replay their own entry after the first cutover" do
    company, project, user = legacy_replay_seeded_actor
    browser_attributes = { duration: 15, work_date: Date.current, note: "Browser create, shared key", bill_status: "unbilled" }
    cli_attributes = { duration: 25, work_date: Date.current, note: "CLI create, shared key", bill_status: "unbilled" }
    browser = legacy_replay_create(company:, project:, user:, key: "legacy-cutover-shared-1",
                                   attributes: browser_attributes, actor_kind: "user")
    cli = legacy_replay_create(company:, project:, user:, key: "legacy-cutover-shared-1",
                               attributes: cli_attributes, actor_kind: "cli")
    expect(cli.id).not_to eq(browser.id)

    timekeeping = legacy_replay_cutover

    recorded = stub_legacy_replay_timekeeping(timekeeping, actor_id: user.id)
    browser_retry, cli_retry = with_forwarded_timekeeping_env do
      [
        legacy_replay_create(company:, project:, user:, key: "legacy-cutover-shared-1",
                             attributes: browser_attributes, actor_kind: "user"),
        legacy_replay_create(company:, project:, user:, key: "legacy-cutover-shared-1",
                             attributes: cli_attributes, actor_kind: "cli")
      ]
    end

    expect(browser_retry.id).to eq(browser.id)
    expect(browser_retry.note).to eq("Browser create, shared key")
    expect(cli_retry.id).to eq(cli.id)
    expect(cli_retry.note).to eq("CLI create, shared key")
    expect(recorded).to eq([])
    expect(TimesheetEntry.unscoped.where(note: ["Browser create, shared key", "CLI create, shared key"]).count).to eq(2)
  end
end

RSpec.describe Timekeeping::Handoff::Runner, "legacy create key reused after the first cutover", :two_tenant_seed,
               :seeded_without_transaction do
  include LegacyCreateReplayAfterCutoverSpecSupport

  # A replay is owed only to a retry "with the same key and body"; a changed body
  # under the key must not replay or write, and a new key is a new create.
  it "after the first cutover the same key with a different note is refused and a new key records exactly one entry" do
    company, project, user = legacy_replay_seeded_actor
    attributes = { duration: 30, work_date: Date.current, note: "Original legacy note", bill_status: "unbilled" }
    first = legacy_replay_create(company:, project:, user:, key: "legacy-cutover-reuse-1", attributes:)

    timekeeping = legacy_replay_cutover

    recorded = stub_legacy_replay_timekeeping(timekeeping, actor_id: user.id)
    with_forwarded_timekeeping_env do
      expect do
        legacy_replay_create(company:, project:, user:, key: "legacy-cutover-reuse-1",
                             attributes: attributes.merge(note: "Changed after the flip"))
      end.to raise_error(Timekeeping::EntryWriteClient::Rejected)
      expect(recorded).to eq([])
      # The stub would also answer 422, so only the absence of any request shows
      # the refusal was made locally, before anything was sent to Timekeeping.
      expect(a_request(:post, %r{\Ahttp://timekeeping\.test/v1/companies/\d+/entries\z})).not_to have_been_made

      legacy_replay_create(company:, project:, user:, key: "legacy-cutover-reuse-2", attributes:)
    end

    expect(recorded.size).to eq(1)
    expect(recorded.first["note"]).to eq("Original legacy note")
    expect(TimesheetEntry.unscoped.where(note: ["Original legacy note", "Changed after the flip"]).pluck(:id))
      .to eq([first.id])
  end
end
