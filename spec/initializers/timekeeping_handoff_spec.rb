# frozen_string_literal: true

require "rails_helper"

RSpec.describe "config/initializers/timekeeping_handoff.rb" do
  # "Capabilities: `Capabilities#refusal` on `configured_owners` is nil for cutover, rollback and re-cutover."
  it "refuses nothing for cutover, rollback and re-cutover on the configured owners" do
    owners = Timekeeping::Handoff::Runner.configured_owners
    routes = {
      cutover: { source_legacy: true, from: "monolith", to: "timekeeping" },
      rollback: { source_legacy: false, from: "timekeeping", to: "monolith" },
      re_cutover: { source_legacy: false, from: "monolith", to: "timekeeping" }
    }

    refusals = routes.transform_values do |route|
      Timekeeping::Handoff::Capabilities.new.refusal(
        source_legacy: route.fetch(:source_legacy),
        outgoing: owners.fetch(route.fetch(:from)),
        incoming: owners.fetch(route.fetch(:to))
      )
    end

    expect(refusals).to eq(cutover: nil, rollback: nil, re_cutover: nil)
  end
end

RSpec.describe "config/initializers/timekeeping_handoff.rb monolith_settle swap" do
  # "Replacing `config.x.timekeeping_handoff.monolith_settle` with an object that lacks `settle!` makes re-cutover refused."
  it "refuses re-cutover but still accepts cutover when monolith_settle lacks settle!" do
    settings = Rails.configuration.x.timekeeping_handoff
    original = settings.monolith_settle
    begin
      settings.monolith_settle = Object.new
      owners = Timekeeping::Handoff::Runner.configured_owners
      capabilities = Timekeeping::Handoff::Capabilities.new

      re_cutover = capabilities.refusal(source_legacy: false, outgoing: owners.fetch("monolith"),
                                        incoming: owners.fetch("timekeeping"))
      cutover = capabilities.refusal(source_legacy: true, outgoing: owners.fetch("monolith"),
                                     incoming: owners.fetch("timekeeping"))

      expect(re_cutover).to eq("monolith has no working settle integration configured")
      expect(cutover).to be_nil
    ensure
      settings.monolith_settle = original
    end
  end
end

RSpec.describe "config/initializers/timekeeping_handoff.rb values" do
  it "configures the monolith admission and the settle and drain classes for both owners" do
    settings = Rails.configuration.x.timekeeping_handoff

    # "`monolith_admission`: `Timekeeping::Handoff::MonolithAdmission`."
    expect(settings.monolith_admission).to be_a(Timekeeping::Handoff::MonolithAdmission)
    expect(settings.monolith_admission.enforces_fence?).to be(true)
    # "`monolith_settle` and `monolith_drain`: `Timekeeping::Handoff::OperationsSettle` and
    # `Timekeeping::Handoff::RelayDrain` with the monolith port."
    # "`timekeeping_settle` and `timekeeping_drain`: the same classes with the Timekeeping port over `TimekeepingStore`."
    expect([settings.monolith_settle, settings.timekeeping_settle]).to all(be_a(Timekeeping::Handoff::OperationsSettle))
    expect([settings.monolith_drain, settings.timekeeping_drain]).to all(be_a(Timekeeping::Handoff::RelayDrain))
    expect(settings.monolith_settle).not_to equal(settings.timekeeping_settle)
    expect(settings.monolith_drain).not_to equal(settings.timekeeping_drain)
  end
end

RSpec.describe "config/initializers/timekeeping_handoff.rb" do
  # "Swapping one configured integration for one that lacks its methods makes that direction refused"
  # Rollback's outgoing owner is Timekeeping, so only its drain is read; re-cutover's outgoing owner is
  # the monolith, so the same swap must not refuse it. Before the initializer exists every value is
  # nil, so re-cutover is refused too and this example fails.
  it "refuses rollback but still accepts re-cutover when the configured timekeeping_drain lacks drained?" do
    settings = Rails.configuration.x.timekeeping_handoff
    original = settings.timekeeping_drain
    settings.timekeeping_drain = Object.new
    begin
      owners = Timekeeping::Handoff::Runner.configured_owners
      capabilities = Timekeeping::Handoff::Capabilities.new

      rollback = capabilities.refusal(source_legacy: false, outgoing: owners.fetch("timekeeping"),
                                      incoming: owners.fetch("monolith"))
      re_cutover = capabilities.refusal(source_legacy: false, outgoing: owners.fetch("monolith"),
                                        incoming: owners.fetch("timekeeping"))

      expect(rollback).to eq("timekeeping has no working drain integration configured")
      expect(re_cutover).to be_nil
    ensure
      settings.timekeeping_drain = original
    end
  end
end
