# frozen_string_literal: true

# The owner integrations Timekeeping::Handoff::Runner.configured_owners reads.
# The handoff classes live under lib/ and are reloadable, so they are built in
# to_prepare: once at boot, and again after each code reload. The legacy
# source's settle and drain are not set here; the runner substitutes
# LegacyOperationsCheck for them.
Rails.application.config.to_prepare do
  handoff = Timekeeping::Handoff
  settings = Rails.configuration.x.timekeeping_handoff
  # One store for both Timekeeping integrations, so settle and drain reach the
  # same server.
  timekeeping_store = handoff::TimekeepingStore.new
  reservations = Invoices::ReservationAdapters::TABLE

  settings.monolith_admission = handoff::MonolithAdmission.new
  settings.monolith_settle = handoff::OperationsSettle.new(
    owner: handoff::OperationsSettle::MonolithPort.new, reservations: reservations.fetch(:prepared).call
  )
  settings.monolith_drain = handoff::RelayDrain.new(owner: handoff::RelayDrain::MonolithPort.new)
  settings.timekeeping_settle = handoff::OperationsSettle.new(
    owner: handoff::OperationsSettle::TimekeepingPort.new(store: timekeeping_store),
    reservations: reservations.fetch(:timekeeping).call
  )
  settings.timekeeping_drain = handoff::RelayDrain.new(owner: handoff::RelayDrain::TimekeepingPort.new(store: timekeeping_store))
end
