# frozen_string_literal: true

require "rails_helper"

RSpec.describe TaxConfiguration, "destroy during a Timekeeping handoff" do
  it "is refused and leaves its invoice taxes' reference in place" do
    invoice_tax = create(:invoice_tax)
    configuration = invoice_tax.tax_configuration
    TimekeepingOwnership.current.update!(handoff_step: "reconcile")

    expect { configuration.destroy }.to raise_error(Timekeeping::BillingFence::OwnershipMoving)
    expect(described_class.exists?(configuration.id)).to be(true)
    expect(invoice_tax.reload.tax_configuration_id).to eq(configuration.id)
  end
end
