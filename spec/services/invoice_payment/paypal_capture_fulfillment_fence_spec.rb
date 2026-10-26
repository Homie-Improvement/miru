# frozen_string_literal: true

require "rails_helper"

RSpec.describe InvoicePayment::PaypalCaptureFulfillment, "during a Timekeeping handoff" do
  let(:company) { create(:company) }
  let(:client_record) { create(:client, company:, currency: "USD") }
  let(:invoice) do
    create(:invoice, company:, client: client_record, currency: "USD", amount: 100, amount_due: 100, amount_paid: 0, status: "sent", payment_infos: { "paypal_order_id" => "ORDER-1" })
  end
  let!(:provider) do
    create(
      :payments_provider,
      company:,
      name: PaymentsProvider::PAYPAL_PROVIDER,
      enabled: true,
      connected: true,
      settings: { client_id: "client-id", environment: "sandbox" }
    ).tap { |record| record.client_secret = "secret"; record.save! }
  end
  let(:paypal_client) { instance_double(PaymentProviders::PaypalClient) }

  before do
    allow(PaymentProviders::PaypalClient).to receive(:new).with(provider:).and_return(paypal_client)
    invoice
    TimekeepingOwnership.current.update!(handoff_step: "settle")
  end

  it "refuses before asking PayPal to capture the payer's money and records nothing" do
    expect(paypal_client).not_to receive(:show_order)
    expect(paypal_client).not_to receive(:capture_order)

    expect {
      expect { described_class.new(invoice:, order_id: "ORDER-1").process }
        .to raise_error(Timekeeping::BillingFence::OwnershipMoving)
    }.not_to change(Payment, :count)
    expect(invoice.reload).to have_attributes(status: "sent", amount_due: 100)
  end
end
