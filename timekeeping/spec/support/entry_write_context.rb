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
# may have written.
RSpec.shared_context "timekeeping entry writes without transactional fixtures" do
  self.use_transactional_tests = false

  after do
    ApplicationRecord.connection.execute(<<~SQL.squish)
      TRUNCATE entries, reservations, audit_events, outbox_snapshots, ownership_generations, idempotency_receipts,
        write_metric_windows, write_metric_events
    SQL
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

RSpec.configure do |config|
  config.include EntryWriteCounts
end
