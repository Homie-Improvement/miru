# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::AlertSignals do
  let(:alert_signals_now) { Time.utc(2026, 3, 3, 12, 7) }
  let(:alert_signals_metrics) do
    { "window_seconds" => 300, "latency_bucket_bounds_ms" => [25, 50, 100, 200, 300, 500, 1000, 2500, 5000],
      "overflow_bucket" => "inf", "total_field" => "writes + reference_unavailable", "companies" => [],
      "outbox_lag" => [{ "company_id" => 11, "oldest_unsent_age_seconds" => 400 }] }
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

  it "lists the four signals with no producer as unavailable and leaves them out of the signals" do
    gathered = gather_alert_signals

    expect(gathered[:unavailable]).to include("ownership_moving", "prepare_refusal", "reconciliation_difference",
                                              "financial_snapshot_change")
    expect(gathered[:signals].keys).not_to include(:ownership_moving, :prepare_refusals, :reconciliation_differences,
                                                   :financial_snapshot_changes)
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
end
