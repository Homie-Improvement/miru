# frozen_string_literal: true

# The process environment, clock and reference stub an entry write needs: an
# RS256 key the service trusts, a service token, a reference endpoint served
# from timekeeping_arrange's catalogue, and a clock that puts the arranged
# work date (2026-03-02) inside the edit window.
RSpec.shared_context "timekeeping entry writes" do
  include ActiveSupport::Testing::TimeHelpers

  let(:provider_service_token) { "service-#{SecureRandom.hex(24)}" }
  let(:timekeeping_arrange) do
    TimekeepingProviderArrange.new(signing_key: TimekeepingProviderArrange.signing_key, service_token: provider_service_token)
  end

  around do |example|
    with_timekeeping_env(
      Timekeeping::Environment::TOKEN_PUBLIC_KEY => TimekeepingProviderArrange.signing_key.public_key.to_pem,
      Timekeeping::Environment::SERVICE_TOKEN => provider_service_token,
      Timekeeping::Environment::SERVICE_CREDENTIALS => nil,
      Timekeeping::Environment::MONOLITH_REFERENCE_URL => TimekeepingProviderArrange::REFERENCE_URL
    ) do
      travel_to(Time.utc(2026, 3, 3, 12)) { example.run }
    end
  end

  before { timekeeping_arrange.stub_reference }

  # An EntryCommand built as the controller builds it, for specs that drive
  # Timekeeping::EntryWriter directly.
  def build_entry_command(route, token:, body: {}, entry_id: nil, key: SecureRandom.uuid,
                          generation: timekeeping_arrange.current_generation, if_match: nil)
    identity = Timekeeping::Identity.resolve(authorization: "Bearer #{token}",
                                             public_key: Timekeeping::Environment.token_public_key,
                                             service_token: provider_service_token)
    headers = { "Idempotency-Key" => key, "Ownership-Generation" => generation.to_s, "If-Match" => if_match }.compact
    Timekeeping::EntryCommand.build(route:, identity:, bearer: token, company_id: identity.company_id,
                                    entry_id: entry_id&.to_s, headers:, raw_body: JSON.generate(body),
                                    reference_client: Timekeeping::ReferenceClient.configured)
  end
end

# For specs that need commits other connections can see: races, and failures
# that must roll a real transaction back. Each example empties the tables it
# may have written, and puts the admission row back to generation 1, so a
# fence or a deleted row never leaks into a later example. Each example also
# starts with those tables' id sequences restarted, because examples that
# roll back still draw ids, and a handoff example asserts exact sequence values.
RSpec.shared_context "timekeeping entry writes without transactional fixtures" do
  self.use_transactional_tests = false

  truncate_entry_write_tables = lambda do
    ApplicationRecord.connection.execute(<<~SQL.squish)
      TRUNCATE entries, reservations, invoice_operations, service_idempotency_receipts, audit_events, outbox_snapshots,
        idempotency_receipts, write_metric_windows, write_metric_events RESTART IDENTITY
    SQL
  end

  before { truncate_entry_write_tables.call }

  after do
    truncate_entry_write_tables.call
    Timekeeping::Admission.ensure_initial!
    Timekeeping::Admission.admit!(generation: 1)
  end
end

# Counts of every table an entry write touches, to show a refused or failed
# write left nothing behind.
module EntryWriteCounts
  def entry_write_counts
    {
      entries: Entry.count, audit_events: AuditEvent.count, outbox_snapshots: OutboxSnapshot.count,
      idempotency_receipts: IdempotencyReceipt.count, versions: Entry.sum(:version)
    }
  end
end

# Holds a company's write_metric_windows row on a connection of its own, so
# metric specs can show what waits on that row and what does not. Needs the
# non-transactional context, because the held row must be committed first.
module MetricWindowLockHelpers
  # Locks company_id's window row FOR UPDATE until the returned release queue
  # is pushed (or 10 seconds pass). Returns the holder thread, the release
  # queue and the holder's server process id.
  def hold_metric_window_row(company_id)
    held = Queue.new
    release = Queue.new
    holder_pid = Queue.new
    holder = Thread.new do
      ApplicationRecord.connection_pool.with_connection do |connection|
        holder_pid << connection.select_value("SELECT pg_backend_pid()")
        connection.transaction do
          connection.execute(ApplicationRecord.sanitize_sql_array(
            ["SELECT 1 FROM write_metric_windows WHERE company_id = ? FOR UPDATE", company_id]
          ))
          held << true
          release.pop(timeout: 10)
        end
      end
    end
    expect(held.pop(timeout: 10)).to be(true)
    [holder, release, holder_pid.pop(timeout: 10)]
  end

  # Polls until some session reports waiting on holding_pid's locks; answers
  # whether one did within five seconds.
  def metric_lock_waiter_seen?(holding_pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      seen = ApplicationRecord.connection.select_value(ApplicationRecord.sanitize_sql_array(
        ["SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE ? = ANY(pg_blocking_pids(pid)))", holding_pid]
      ))
      return true if seen

      sleep 0.02
    end
    false
  end
end

RSpec.configure do |config|
  config.include EntryWriteCounts
  config.include MetricWindowLockHelpers
end
