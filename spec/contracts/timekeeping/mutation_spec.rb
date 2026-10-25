# frozen_string_literal: true

require "rails_helper"
require_relative "entry_api_examples"
require_relative "entry_snapshot_examples"
require_relative "idempotency_examples"
require_relative "prepare_reconciliation_examples"
require_relative "reservations_examples"

# Proves the shared contract examples catch a broken implementation: each row
# builds the fakes with exactly one rule broken, runs the group that owns the
# rule, and expects it to fail through a failed expectation, not an error.
RSpec.describe "Timekeeping contract examples against fakes with one rule broken" do
  # Runs a shared group against fakes built with the given policies, in a
  # group the surrounding run does not register or report, and returns each
  # inner example's exception (nil for a pass).
  def run_contract_group(group_name, group_options, timekeeping: {}, relay: {}, reconciler: {})
    exceptions = []
    listener = Object.new
    listener.define_singleton_method(:example_finished) { |notification| exceptions << notification.example.execution_result.exception }
    reporter = RSpec::Core::Reporter.new(RSpec::Core::Configuration.new)
    reporter.register_listener(listener, :example_finished)

    group = RSpec::Core::ExampleGroup.subclass(RSpec::Core::ExampleGroup, "fakes with policies", [{}], []) do
      include_context "timekeeping contract fakes"
      let(:timekeeping_fake_policies) { timekeeping }
      let(:timekeeping_relay_policies) { relay }
      let(:timekeeping_reconciler_policies) { reconciler }

      it_behaves_like group_name, **group_options
    end

    outer_example = RSpec.current_example
    group.run(reporter)
    exceptions
  ensure
    RSpec.current_example = outer_example
    RSpec.current_scope = :example
  end

  groups = {
    entry_api: ["timekeeping entry API contract", {}],
    reservations: ["timekeeping reservations contract", {}],
    timekeeping_idempotency: ["timekeeping idempotency contract", { contracts: [:entry_api, :reservations] }],
    snapshot_idempotency: ["timekeeping idempotency contract", { contracts: [:entry_snapshots] }],
    snapshot_shape: ["timekeeping entry snapshot shape", {}],
    snapshot_endpoint: ["timekeeping entry snapshot endpoint", {}],
    reconciliation: ["timekeeping prepare reconciliation", {}]
  }

  stale_generation_accepted = ->(**) { true }
  duration_in_hours = ->(stored) { stored / 60.0 }
  foreign_entries_visible = ->(entry:, **) { !entry.nil? && entry["discarded_at"].nil? }

  mutants = [
    ["keeps locked after its reservation is gone", :reservations,
     { timekeeping: { locked: ->(reserved:, was_locked:) { reserved || was_locked } } }],
    ["converts duration to hours in entry responses", :entry_api, { timekeeping: { duration: duration_in_hours } }],
    ["converts duration to hours in snapshots", :snapshot_shape, { timekeeping: { duration: duration_in_hours } }],
    ["omits 409 stale_generation on the entry API", :entry_api, { timekeeping: { generation_current: stale_generation_accepted } }],
    ["omits 409 stale_generation on reservations", :reservations, { timekeeping: { generation_current: stale_generation_accepted } }],
    ["omits 409 stale_generation at the snapshot endpoint", :snapshot_endpoint, { relay: { generation_accepted: stale_generation_accepted } }],
    ["omits 422 idempotency_key_reused at Timekeeping", :timekeeping_idempotency, { timekeeping: { reject_reused_key: false } }],
    ["omits 422 idempotency_key_reused at the snapshot endpoint", :snapshot_idempotency, { relay: { reject_reused_key: false } }],
    ["keys receipts by the key alone", :timekeeping_idempotency,
     { timekeeping: { receipt_key: ->(operation:, key:, **) { [operation, key] } } }],
    ["looks up operations without the actor", :timekeeping_idempotency,
     { timekeeping: { operation_key: ->(company_id:, operation_id:, **) { [company_id, operation_id] } } }],
    ["keys snapshot receipts without the company scope", :snapshot_idempotency,
     { relay: { receipt_key: ->(actor:, operation:, key:, **) { [actor, operation, key] } } }],
    ["keeps partial reservations from a refused prepare", :reservations,
     { timekeeping: { refused_prepare: ->(free_entry_ids:, **) { { reserve: free_entry_ids, release: [] } } } }],
    ["releases another invoice's reservation on a refused prepare", :reservations,
     { timekeeping: { refused_prepare: ->(conflicting_entry_ids:, **) { { reserve: [], release: conflicting_entry_ids } } } }],
    ["re-reserves on a prepare for a terminal operation", :reservations, { timekeeping: { replay_terminal_prepare: false } }],
    ["shows another company's entry on the entry API", :entry_api, { timekeeping: { entry_visible: foreign_entries_visible } }],
    ["reserves another company's entry", :reservations, { timekeeping: { entry_visible: foreign_entries_visible } }],
    ["accepts a user token on the reservation routes", :reservations,
     { timekeeping: { service_access: ->(kind:, **) { kind.nil? ? :unauthorized : :ok } } }],
    ["applies a lower snapshot version", :snapshot_endpoint, { relay: { apply_version: ->(**) { true } } }],
    ["deletes a tombstoned entry from the projection", :snapshot_endpoint, { relay: { delete_tombstones: true } }],
    ["adds the user's email to the snapshot", :snapshot_shape,
     { timekeeping: { snapshot_entry: ->(entry, **) { entry.merge("user_email" => "employee@example.test") } } }],
    ["copies a credential into proof_metadata", :snapshot_shape,
     { timekeeping: { snapshot_entry: lambda do |entry, credentials:|
       entry.merge("proof_metadata" => entry["proof_metadata"].to_h.merge("authorization" => credentials.join(" ")))
     end } }],
    ["lets an employee name another user", :entry_api,
     { timekeeping: { target_user: ->(requested_id:, **) { requested_id.nil? ? :acting : :requested } } }],
    ["accepts the previous generation past the final outbox position", :snapshot_endpoint,
     { relay: { generation_accepted: lambda do |generation:, current:, handoff:, **|
       generation == current || (!handoff.nil? && generation == handoff[:previous_generation])
     end } }],
    ["reports success for a committed operation whose intent is pending", :reconciliation,
     { reconciler: { outcome: ->(table, remote_state:, **) { remote_state == "committed" ? table.fetch("rows").first : table.fetch("fallback") } } }],
    ["stores a 409 as a snapshot receipt", :snapshot_idempotency, { relay: { store_answer: ->(**) { true } } }],
    ["accepts an entry body that carries a credential", :entry_api, { timekeeping: { credential_in_body: ->(**) { false } } }],
    ["keys snapshot receipts without the actor", :snapshot_idempotency,
     { relay: { receipt_key: ->(company_scope:, operation:, key:, **) { [company_scope, operation, key] } } }]
  ]

  it "passes every group with the unbroken fakes" do
    groups.each_value do |group_name, group_options|
      exceptions = run_contract_group(group_name, group_options)

      expect(exceptions).not_to be_empty
      expect(exceptions.compact.map(&:message)).to eq([]), "#{group_name} failed with the unbroken fakes"
    end
  end

  mutants.each do |rule, group_key, policies|
    it "fails the #{group_key} examples when the fake #{rule}" do
      group_name, group_options = groups.fetch(group_key)

      exceptions = run_contract_group(group_name, group_options, **policies)
      failures = exceptions.compact
      errors = failures.reject { |exception| exception.is_a?(RSpec::Expectations::ExpectationNotMetError) }

      expect(exceptions).not_to be_empty
      expect(failures).not_to be_empty, "no example in #{group_name} failed"
      expect(errors.map { |error| "#{error.class}: #{error.message}" }).to eq([])
    end
  end
end
