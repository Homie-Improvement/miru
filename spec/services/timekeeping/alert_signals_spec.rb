# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::AlertSignals do
  include ActiveSupport::Testing::TimeHelpers

  let(:alert_signals_now) { Time.utc(2026, 3, 3, 12, 7) }
  let(:alert_signals_metrics) do
    timekeeping_alerts_metrics_body(outbox_lag: [{ "company_id" => 11, "oldest_unsent_age_seconds" => 400 }])
  end

  def alert_signals_client(body: nil, error: nil)
    client = Object.new
    client.define_singleton_method(:fetch) { error ? raise(error) : body }
    client
  end

  def gather_alert_signals(client = alert_signals_client(body: alert_signals_metrics))
    described_class.gather(metrics_client: client, now: alert_signals_now)
  end

  before { TimekeepingOwnership.ensure_initial! }

  it "lists the signals with no producer as unavailable and leaves them out of the signals" do
    gathered = gather_alert_signals

    expect(gathered[:unavailable]).to include("ownership_moving")
    expect(gathered[:unavailable]).not_to include("prepare_refusal", "reconciliation_difference", "financial_snapshot_change")
    expect(gathered[:signals].keys).not_to include(:ownership_moving)
    expect(gathered[:signals]).to include(prepare_refusals: [], reconciliation_differences: [], financial_snapshot_changes: [])
    expect(gathered[:metrics_error]).to be_nil
  end

  it "marks outbox lag unavailable while the monolith owns entries and reads it once Timekeeping owns them" do
    expect(gather_alert_signals[:unavailable]).to include("outbox_lag")

    TimekeepingOwnership.current.update_columns(owner: "timekeeping")
    gathered = gather_alert_signals

    expect(gathered[:unavailable]).not_to include("outbox_lag")
    expect(Timekeeping::Alerts.evaluate(gathered[:signals]).map { |alert| [alert.name, alert.company_id] })
      .to eq([["outbox_lag", 11]])
  end

  it "reports only each company's oldest pending intent, ignoring committed ones" do
    InvoiceOperationIntent.create!(company_id: 21, invoice_id: 1, operation_id: SecureRandom.uuid, generation: 1,
                                   state: "pending", created_at: alert_signals_now - 11.minutes)
    InvoiceOperationIntent.create!(company_id: 21, invoice_id: 2, operation_id: SecureRandom.uuid, generation: 1,
                                   state: "pending", created_at: alert_signals_now - 1.minute)
    InvoiceOperationIntent.create!(company_id: 22, invoice_id: 3, operation_id: SecureRandom.uuid, generation: 1,
                                   state: "committed", created_at: alert_signals_now - 1.hour)

    expect(gather_alert_signals[:signals][:pending_intents])
      .to eq([{ company_id: 21, oldest_created_at: alert_signals_now - 11.minutes }])
  end

  it "counts stale_generation refusals only inside the lookback and leaves the handoff filter to the evaluator" do
    TimekeepingStaleGenerationRefusal.create!(company_id: 31, handoff_step: nil, created_at: alert_signals_now - 1.minute)
    TimekeepingStaleGenerationRefusal.create!(company_id: 32, handoff_step: "freeze", created_at: alert_signals_now - 1.minute)
    TimekeepingStaleGenerationRefusal.create!(company_id: 33, handoff_step: nil, created_at: alert_signals_now - 11.minutes)

    gathered = gather_alert_signals

    expect(gathered[:signals][:stale_generation_refusals]).to contain_exactly(
      { company_id: 31, handoff_step: nil, count: 1 }, { company_id: 32, handoff_step: "freeze", count: 1 }
    )
    expect(Timekeeping::Alerts.evaluate(gathered[:signals]).map(&:company_id)).to eq([31])
  end

  it "keeps the monolith signals and sets metrics_error when the metrics read fails" do
    TimekeepingOwnership.current.update_columns(owner: "timekeeping")
    client = alert_signals_client(error: Timekeeping::MetricsClient::Error.new("Timekeeping metrics answered 401"))

    gathered = gather_alert_signals(client)

    expect(gathered[:metrics_error]).to eq("Timekeeping metrics answered 401")
    expect(gathered[:unavailable]).to include("reference_unavailable_rate", "entry_write_p95_latency", "outbox_lag")
    expect(gathered[:signals]).to include(:pending_intents, :stale_generation_refusals)
    expect(gathered[:signals]).not_to include(:write_metrics, :outbox_lag_by_owner)
  end

  # "Printing unavailable is honest, but it does not deliver the requested local alerts."
  # A failed read must not look like a healthy zero, and must not stop the other signals.
  it "reports event-history signals as unavailable rather than empty when the event history cannot be read" do
    TimekeepingStaleGenerationRefusal.create!(company_id: 41, handoff_step: nil, created_at: alert_signals_now - 1.minute)
    allow(RailsEventViewer::Entry).to receive(:where).and_raise(ActiveRecord::StatementInvalid, "event history down")

    gathered = gather_alert_signals(alert_signals_client(body: timekeeping_alerts_metrics_body))

    expect(gathered[:unavailable]).to include("reconciliation_difference", "financial_snapshot_change")
    expect(gathered[:signals].keys).not_to include(:reconciliation_differences, :financial_snapshot_changes)
    expect(Timekeeping::Alerts.evaluate(gathered[:signals]).map { |alert| [alert.name, alert.company_id] })
      .to include(["stale_generation", 41])
  end

  # "Consequently, `timekeeping:alerts` cannot alert operators about these conditions, even when they occur."
  # Event history is free-form JSON; a row missing company_id or the listed flag must neither crash
  # the gatherer nor be dropped, so it counts as unexplained under no company (printed company_id=all).
  it "still alerts under no company for a stored reconciliation event whose payload lacks company_id and listed" do
    RailsEventViewer::Entry.create!(
      name: "Timekeeping::ReconciliationDifferenceFound", occurred_at: alert_signals_now - 1.minute,
      payload: { "data" => { "check" => "entries" } }
    )

    gathered = gather_alert_signals(alert_signals_client(body: timekeeping_alerts_metrics_body))

    expect(gathered[:unavailable]).not_to include("reconciliation_difference")
    expect(Timekeeping::Alerts.evaluate(gathered[:signals]).map { |alert| [alert.name, alert.company_id] })
      .to include(["reconciliation_difference", nil])
  end

  # "Add units that gather the required real signals and prove the command reports them."
  # A rerun after a failed alert delivery must see the same signal, so gathering only reads.
  it "gives the same financial snapshot count on a second run and leaves the event history untouched" do
    difference = Timekeeping::FinancialSnapshot::Difference.new(
      company_id: 51, kind: :invoice, record_id: 9, field: :amount, old_value: nil, new_value: nil
    )
    travel_to(alert_signals_now - 1.minute) { Timekeeping::FinancialSnapshot.report([difference]) }
    client = alert_signals_client(body: timekeeping_alerts_metrics_body)
    stored = RailsEventViewer::Entry.where(name: "Timekeeping::FinancialSnapshotChanged")
    stored_before = stored.count

    first = gather_alert_signals(client)
    second = gather_alert_signals(client)

    expect(first[:signals][:financial_snapshot_changes]).to eq([{ company_id: 51, count: 1 }])
    expect(second[:signals][:financial_snapshot_changes]).to eq(first[:signals][:financial_snapshot_changes])
    expect(stored.count).to eq(stored_before)
  end
end
