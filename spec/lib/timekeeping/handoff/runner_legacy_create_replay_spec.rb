# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe Timekeeping::Handoff::Runner, "legacy create replayed after the first cutover", :two_tenant_seed,
               :seeded_without_transaction do
  # "A create whose first attempt committed in the legacy store with an Idempotency-Key, retried with the same key and body after the first cutover flip, replays the original entry from Timekeeping, and the test shows no second entry was recorded."
  it "a legacy keyed create retried with the same key and body after the first cutover replays the original entry from Timekeeping and records no second entry" do
    company = fork_and_leaf
    user = company.users.find { |candidate| candidate.has_role?(:owner, company) || candidate.has_role?(:admin, company) }
    project = company.projects.find_by!(billable: true)
    key = "legacy-timer-key-cutover-1"
    attributes = { duration: 45.0, work_date: Date.current.iso8601, note: "Committed in legacy", bill_status: "unbilled" }
    create_once = lambda do |request_id|
      context = Timekeeping::WriteContext.new(company:, actor: user, actor_kind: "user", request_id:, idempotency_key: key)
      Timekeeping::Gateway.new(context:).create(user:, project:, attributes:)
    end

    first = create_once.call("legacy-attempt-1")

    timekeeping = TimekeepingHandoffFakes::InMemoryTimekeepingStore.new
    described_class.run(direction: :cutover, owners: TimekeepingHandoffFakes.owners(timekeeping:),
                        report_root: Dir.mktmpdir("handoff-report"))
    expect(TimekeepingOwnership.current.owner).to eq("timekeeping")

    # Answers a keyed create the way Timekeeping's entry writer does: a stored
    # receipt for the same company, user actor, operation and key replays when
    # the SHA-256 of the regenerated JSON body matches, and anything else writes.
    new_writes = []
    json = { "Content-Type" => "application/json" }
    stub_request(:post, %r{timekeeping\.test/v1/companies/\d+/entries\z}).to_return do |request|
      company_id = Integer(request.uri.path[%r{companies/(\d+)}, 1], 10)
      sent_key = request.headers.find { |name, _value| name.to_s.casecmp?("Idempotency-Key") }&.last
      body = JSON.parse(request.body)
      fingerprint = Digest::SHA256.hexdigest(JSON.generate(body))
      receipt = timekeeping.rows.fetch("idempotency_records").find do |row|
        row["company_id"] == company_id && row["actor_type"] == "user" && row["actor_id"] == user.id &&
          row["operation"] == "create " && row["key"] == sent_key
      end
      if receipt && receipt["fingerprint"] == fingerprint
        { status: receipt["status"], body: receipt["body"], headers: json }
      elsif receipt
        { status: 422, body: JSON.generate("reason" => "idempotency_key_reused"), headers: json }
      else
        new_writes << body
        { status: 201, headers: json,
          body: JSON.generate(body.merge("id" => 900_000 + new_writes.size, "company_id" => company_id, "version" => 1,
                                         "review_status" => "pending", "locked" => false)) }
      end
    end
    entries_before_retry = TimesheetEntry.unscoped.count

    retried = with_forwarded_timekeeping_env { create_once.call("retry-after-flip") }

    expect(retried.id).to eq(first.id)
    expect(retried.note).to eq("Committed in legacy")
    expect(new_writes).to be_empty
    expect(TimesheetEntry.unscoped.count).to eq(entries_before_retry)
  end
end

RSpec.describe Timekeeping::Handoff::Runner, "legacy create replayed after a billing default change", :two_tenant_seed,
               :seeded_without_transaction do
  # "A create whose first attempt committed in the legacy store with an Idempotency-Key, retried with the same key and body after the first cutover flip, replays the original entry from Timekeeping, and the test shows no second entry was recorded."
  # The retry sends the same request values; only the project's billing default changed in between.
  it "a legacy create without bill_status replays after the first cutover even though its project became non-billable before the flip" do
    company = fork_and_leaf
    user = company.users.find { |candidate| candidate.has_role?(:owner, company) || candidate.has_role?(:admin, company) }
    project = company.projects.find_by!(billable: true)
    key = "legacy-timer-key-billing-default-1"
    attributes = { duration: 30.0, work_date: Date.current.iso8601, note: "Billable when first sent" }
    create_once = lambda do |request_id|
      context = Timekeeping::WriteContext.new(company:, actor: user, actor_kind: "user", request_id:, idempotency_key: key)
      Timekeeping::Gateway.new(context:).create(user:, project:, attributes:)
    end

    first = create_once.call("legacy-billing-attempt-1")
    project.update_columns(billable: false)

    timekeeping = TimekeepingHandoffFakes::InMemoryTimekeepingStore.new
    described_class.run(direction: :cutover, owners: TimekeepingHandoffFakes.owners(timekeeping:),
                        report_root: Dir.mktmpdir("handoff-report"))

    new_writes = []
    json = { "Content-Type" => "application/json" }
    stub_request(:post, %r{timekeeping\.test/v1/companies/\d+/entries\z}).to_return do |request|
      company_id = Integer(request.uri.path[%r{companies/(\d+)}, 1], 10)
      sent_key = request.headers.find { |name, _value| name.to_s.casecmp?("Idempotency-Key") }&.last
      body = JSON.parse(request.body)
      fingerprint = Digest::SHA256.hexdigest(JSON.generate(body))
      receipt = timekeeping.rows.fetch("idempotency_records").find do |row|
        row["company_id"] == company_id && row["actor_type"] == "user" && row["actor_id"] == user.id &&
          row["operation"] == "create " && row["key"] == sent_key
      end
      if receipt && receipt["fingerprint"] == fingerprint
        { status: receipt["status"], body: receipt["body"], headers: json }
      elsif receipt
        { status: 422, body: JSON.generate("reason" => "idempotency_key_reused"), headers: json }
      else
        new_writes << body
        { status: 201, headers: json,
          body: JSON.generate(body.merge("id" => 900_100 + new_writes.size, "company_id" => company_id, "version" => 1,
                                         "review_status" => "pending", "locked" => false)) }
      end
    end
    entries_before_retry = TimesheetEntry.unscoped.count

    retried = with_forwarded_timekeeping_env { create_once.call("retry-after-billing-change") }

    expect(retried.id).to eq(first.id)
    expect(retried.note).to eq("Billable when first sent")
    expect(new_writes).to be_empty
    expect(TimesheetEntry.unscoped.count).to eq(entries_before_retry)
  end
end

RSpec.describe Timekeeping::Handoff::Runner, "legacy creates of two actor kinds replayed after the first cutover",
               :two_tenant_seed, :seeded_without_transaction do
  # "A create whose first attempt committed in the legacy store with an Idempotency-Key, retried with the same key and body after the first cutover flip, replays the original entry from Timekeeping, and the test shows no second entry was recorded."
  it "a browser create and a command-line create under one client key each replay their own legacy entry after the first cutover" do
    company = fork_and_leaf
    user = company.users.find { |candidate| candidate.has_role?(:owner, company) || candidate.has_role?(:admin, company) }
    project = company.projects.find_by!(billable: true)
    key = "shared-client-key-across-kinds-1"
    notes = { "user" => "Logged in the browser", "cli" => "Logged from the command line" }
    create_once = lambda do |actor_kind, request_id|
      context = Timekeeping::WriteContext.new(company:, actor: user, actor_kind:, request_id:, idempotency_key: key)
      attributes = { duration: 15.0, work_date: Date.current.iso8601, note: notes.fetch(actor_kind), bill_status: "unbilled" }
      Timekeeping::Gateway.new(context:).create(user:, project:, attributes:)
    end

    first_by_kind = notes.keys.index_with { |actor_kind| create_once.call(actor_kind, "legacy-#{actor_kind}-1") }
    expect(first_by_kind.values.map(&:id).uniq.size).to eq(2)

    timekeeping = TimekeepingHandoffFakes::InMemoryTimekeepingStore.new
    described_class.run(direction: :cutover, owners: TimekeepingHandoffFakes.owners(timekeeping:),
                        report_root: Dir.mktmpdir("handoff-report"))

    new_writes = []
    json = { "Content-Type" => "application/json" }
    stub_request(:post, %r{timekeeping\.test/v1/companies/\d+/entries\z}).to_return do |request|
      company_id = Integer(request.uri.path[%r{companies/(\d+)}, 1], 10)
      sent_key = request.headers.find { |name, _value| name.to_s.casecmp?("Idempotency-Key") }&.last
      body = JSON.parse(request.body)
      fingerprint = Digest::SHA256.hexdigest(JSON.generate(body))
      receipt = timekeeping.rows.fetch("idempotency_records").find do |row|
        row["company_id"] == company_id && row["actor_type"] == "user" && row["actor_id"] == user.id &&
          row["operation"] == "create " && row["key"] == sent_key
      end
      if receipt && receipt["fingerprint"] == fingerprint
        { status: receipt["status"], body: receipt["body"], headers: json }
      elsif receipt
        { status: 422, body: JSON.generate("reason" => "idempotency_key_reused"), headers: json }
      else
        new_writes << body
        { status: 201, headers: json,
          body: JSON.generate(body.merge("id" => 900_200 + new_writes.size, "company_id" => company_id, "version" => 1,
                                         "review_status" => "pending", "locked" => false)) }
      end
    end
    entries_before_retry = TimesheetEntry.unscoped.count

    retried_by_kind = with_forwarded_timekeeping_env do
      notes.keys.index_with { |actor_kind| create_once.call(actor_kind, "retry-#{actor_kind}-after-flip") }
    end

    notes.each do |actor_kind, note|
      expect(retried_by_kind.fetch(actor_kind).id).to eq(first_by_kind.fetch(actor_kind).id)
      expect(retried_by_kind.fetch(actor_kind).note).to eq(note)
    end
    expect(new_writes).to be_empty
    expect(TimesheetEntry.unscoped.count).to eq(entries_before_retry)
  end
end

RSpec.describe Timekeeping::Handoff::Runner, :two_tenant_seed, :seeded_without_transaction do
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

  # "A create whose first attempt committed in the legacy store with an Idempotency-Key, retried with the same key and body after the first cutover flip, replays the original entry from Timekeeping, and the test shows no second entry was recorded."
  it "a keyed legacy create retried with the same key and body after the first cutover replays the original entry from Timekeeping and records no second entry" do
    company, project, user = legacy_replay_seeded_actor
    attributes = { duration: 45, work_date: Date.current, note: "Legacy timer before cutover", bill_status: "unbilled" }
    first = legacy_replay_create(company:, project:, user:, key: "legacy-cutover-replay-1", attributes:)
    expect(TimesheetEntry.unscoped.where(note: "Legacy timer before cutover").count).to eq(1)

    timekeeping = TimekeepingHandoffFakes::InMemoryTimekeepingStore.new
    described_class.run(direction: :cutover, owners: TimekeepingHandoffFakes.owners(timekeeping:),
                        report_root: Dir.mktmpdir("handoff-report"))
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

RSpec.describe Timekeeping::Handoff::Runner, :two_tenant_seed, :seeded_without_transaction do
  def legacy_replay_billing_actor
    company = Company.order(:id).find { |candidate| candidate.projects.where(billable: true).exists? }
    project = company.projects.where(billable: true).order(:id).first
    user = company.users.order(:id).find { |member| member.has_role?(:owner, company) || member.has_role?(:admin, company) }
    [company, project, user]
  end

  def legacy_replay_billing_create(company:, project:, user:, key:, attributes:)
    context = Timekeeping::WriteContext.new(company:, actor: user, actor_kind: "user", request_id: SecureRandom.uuid,
                                            idempotency_key: key)
    Timekeeping::Gateway.new(context:).create(user:, project:, attributes:)
  end

  # Answers a forwarded create from a receipt Timekeeping holds, by the
  # receipt rule of Timekeeping's EntryWriter, or records a new entry.
  def stub_legacy_replay_billing_timekeeping(timekeeping, actor_id:)
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
          .merge("id" => 9_100_000 + recorded.size, "company_id" => company_id, "version" => 1, "locked" => false)
        { status: 201, body: JSON.generate(entry), headers: }
      end
    end
    recorded
  end

  # "A create whose first attempt committed in the legacy store with an Idempotency-Key, retried with the same key and body after the first cutover flip, replays the original entry from Timekeeping, and the test shows no second entry was recorded."
  # The request body is unchanged; only the project's billing default, which the
  # forwarded body is filled from, changed between the attempts.
  it "a legacy create sent without bill_status still replays after cutover when its project became non-billable before the flip" do
    company, project, user = legacy_replay_billing_actor
    attributes = { duration: 30, work_date: Date.current, note: "Billing default changed later" }
    first = legacy_replay_billing_create(company:, project:, user:, key: "legacy-cutover-billing-1", attributes:)
    project.update_columns(billable: false)

    timekeeping = TimekeepingHandoffFakes::InMemoryTimekeepingStore.new
    described_class.run(direction: :cutover, owners: TimekeepingHandoffFakes.owners(timekeeping:),
                        report_root: Dir.mktmpdir("handoff-report"))

    recorded = stub_legacy_replay_billing_timekeeping(timekeeping, actor_id: user.id)
    retried = with_forwarded_timekeeping_env do
      legacy_replay_billing_create(company:, project:, user:, key: "legacy-cutover-billing-1", attributes:)
    end

    expect(retried.id).to eq(first.id)
    expect(recorded).to eq([])
    expect(TimesheetEntry.unscoped.where(note: "Billing default changed later").count).to eq(1)
  end
end

RSpec.describe Timekeeping::Handoff::Runner, :two_tenant_seed, :seeded_without_transaction do
  def legacy_replay_kinds_actor
    company = Company.order(:id).find { |candidate| candidate.projects.where(billable: true).exists? }
    project = company.projects.where(billable: true).order(:id).first
    user = company.users.order(:id).find { |member| member.has_role?(:owner, company) || member.has_role?(:admin, company) }
    [company, project, user]
  end

  def legacy_replay_kinds_create(company:, project:, user:, key:, attributes:, actor_kind:)
    context = Timekeeping::WriteContext.new(company:, actor: user, actor_kind:, request_id: SecureRandom.uuid,
                                            idempotency_key: key)
    Timekeeping::Gateway.new(context:).create(user:, project:, attributes:)
  end

  # Answers a forwarded create from a receipt Timekeeping holds, by the
  # receipt rule of Timekeeping's EntryWriter, or records a new entry.
  def stub_legacy_replay_kinds_timekeeping(timekeeping, actor_id:)
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
          .merge("id" => 9_200_000 + recorded.size, "company_id" => company_id, "version" => 1, "locked" => false)
        { status: 201, body: JSON.generate(entry), headers: }
      end
    end
    recorded
  end

  # "A create whose first attempt committed in the legacy store with an Idempotency-Key, retried with the same key and body after the first cutover flip, replays the original entry from Timekeeping, and the test shows no second entry was recorded."
  it "a browser create and a command-line create under one client key each replay their own entry after the first cutover" do
    company, project, user = legacy_replay_kinds_actor
    browser_attributes = { duration: 15, work_date: Date.current, note: "Browser create, shared key", bill_status: "unbilled" }
    cli_attributes = { duration: 25, work_date: Date.current, note: "CLI create, shared key", bill_status: "unbilled" }
    browser = legacy_replay_kinds_create(company:, project:, user:, key: "legacy-cutover-shared-1",
                                         attributes: browser_attributes, actor_kind: "user")
    cli = legacy_replay_kinds_create(company:, project:, user:, key: "legacy-cutover-shared-1",
                                     attributes: cli_attributes, actor_kind: "cli")
    expect(cli.id).not_to eq(browser.id)

    timekeeping = TimekeepingHandoffFakes::InMemoryTimekeepingStore.new
    described_class.run(direction: :cutover, owners: TimekeepingHandoffFakes.owners(timekeeping:),
                        report_root: Dir.mktmpdir("handoff-report"))

    recorded = stub_legacy_replay_kinds_timekeeping(timekeeping, actor_id: user.id)
    browser_retry, cli_retry = with_forwarded_timekeeping_env do
      [
        legacy_replay_kinds_create(company:, project:, user:, key: "legacy-cutover-shared-1",
                                   attributes: browser_attributes, actor_kind: "user"),
        legacy_replay_kinds_create(company:, project:, user:, key: "legacy-cutover-shared-1",
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

RSpec.describe Timekeeping::Handoff::Runner, :two_tenant_seed, :seeded_without_transaction do
  def legacy_replay_reuse_actor
    company = Company.order(:id).find { |candidate| candidate.projects.where(billable: true).exists? }
    project = company.projects.where(billable: true).order(:id).first
    user = company.users.order(:id).find { |member| member.has_role?(:owner, company) || member.has_role?(:admin, company) }
    [company, project, user]
  end

  def legacy_replay_reuse_create(company:, project:, user:, key:, attributes:)
    context = Timekeeping::WriteContext.new(company:, actor: user, actor_kind: "user", request_id: SecureRandom.uuid,
                                            idempotency_key: key)
    Timekeeping::Gateway.new(context:).create(user:, project:, attributes:)
  end

  # Answers a forwarded create from a receipt Timekeeping holds, by the
  # receipt rule of Timekeeping's EntryWriter, or records a new entry.
  def stub_legacy_replay_reuse_timekeeping(timekeeping, actor_id:)
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
          .merge("id" => 9_300_000 + recorded.size, "company_id" => company_id, "version" => 1, "locked" => false)
        { status: 201, body: JSON.generate(entry), headers: }
      end
    end
    recorded
  end

  # A replay is owed only to a retry "with the same key and body"; a changed body
  # under the key must not replay or write, and a new key is a new create.
  it "after the first cutover the same key with a different note is refused and a new key records exactly one entry" do
    company, project, user = legacy_replay_reuse_actor
    attributes = { duration: 30, work_date: Date.current, note: "Original legacy note", bill_status: "unbilled" }
    legacy_replay_reuse_create(company:, project:, user:, key: "legacy-cutover-reuse-1", attributes:)

    timekeeping = TimekeepingHandoffFakes::InMemoryTimekeepingStore.new
    described_class.run(direction: :cutover, owners: TimekeepingHandoffFakes.owners(timekeeping:),
                        report_root: Dir.mktmpdir("handoff-report"))

    recorded = stub_legacy_replay_reuse_timekeeping(timekeeping, actor_id: user.id)
    with_forwarded_timekeeping_env do
      expect do
        legacy_replay_reuse_create(company:, project:, user:, key: "legacy-cutover-reuse-1",
                                   attributes: attributes.merge(note: "Changed after the flip"))
      end.to raise_error(Timekeeping::EntryWriteClient::Rejected)
      expect(recorded).to eq([])

      legacy_replay_reuse_create(company:, project:, user:, key: "legacy-cutover-reuse-2", attributes:)
    end

    expect(recorded.size).to eq(1)
    expect(recorded.first["note"]).to eq("Original legacy note")
  end
end
