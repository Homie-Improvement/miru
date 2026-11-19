# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::Handoff::OperationsSettle::MonolithPort do
  include PreparedReservationsSpecSupport
  include TimekeepingLocalOwnerSpecHelpers

  # "Settle ends only when no intent is 'pending' and no operation is 'prepared'"
  it "the monolith port counts a prepared operation, so settle is not done until that operation leaves 'prepared'" do
    g = prepare_local_ownership!.generation
    company = create(:company)
    entry = prepared_spec_entry(company)
    invoice = prepared_spec_invoice(company)
    request = prepared_spec_request(company, invoice, [entry.id])
    adapter = Invoices::PreparedReservations.new
    expect(adapter.prepare(request).state).to eq("prepared")
    TimekeepingOwnership.current.update_columns(generation: g + 1, handoff_step: "settle")

    port = described_class.new(connection: ActiveRecord::Base.connection)
    settle = Timekeeping::Handoff::OperationsSettle.new(
      owner: port, reservations: adapter, connection: ActiveRecord::Base.connection
    )

    expect(port.begin_settling(generation: g)).to be(true)
    expect(port.prepared_operations).to eq(1)
    # No intent is pending here, so only the prepared operation keeps settle open.
    expect(settle.settled?).to be(false)

    expect(adapter.abort(request).state).to eq("aborted")

    expect(port.prepared_operations).to eq(0)
    expect(settle.settled?).to be(true)
  end
end

RSpec.describe Timekeeping::Handoff::OperationsSettle::TimekeepingPort do
  # "Settle begins settling at that generation minus one, the outgoing one, and never accepts the raised generation."
  it "settle! through the Timekeeping port asks Timekeeping to settle generation 4 when given the raised generation 5, never 5" do
    store = instance_double(Timekeeping::Handoff::TimekeepingStore)
    allow(store).to receive(:settle).and_return(
      Timekeeping::Handoff::TimekeepingStore::SettleAnswer.new(settling: true, prepared_operations: 0)
    )
    settle = Timekeeping::Handoff::OperationsSettle.new(
      owner: described_class.new(store:), reservations: double("reservations"),
      connection: ActiveRecord::Base.connection
    )

    settle.settle!(generation: 5)

    expect(store).to have_received(:settle).with(generation: 4).at_least(:once)
    expect(store).not_to have_received(:settle).with(generation: 5)
  end
end
