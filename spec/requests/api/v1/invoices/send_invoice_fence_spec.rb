# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Invoices#send_invoice and the billing fence", type: :request do
  include ActiveJob::TestHelper

  let(:invoice) { create :invoice_with_invoice_line_items, status: "draft" }
  let(:company) { invoice.company }
  let(:user) { create :user, current_workspace_id: company.id }
  let(:invoice_email) { { subject: "Invoice", recipients: ["client@example.com"], message: "Hello" } }

  before do
    create(:employment, company:, user:)
    user.add_role :admin, company
    sign_in user
    allow(InvoicePayment::PdfGeneration).to receive(:process).and_return("%PDF-1.4")
    invoice
    clear_enqueued_jobs
  end

  it "answers 503 during a handoff without queuing any job or marking the invoice sent" do
    TimekeepingOwnership.current.update!(handoff_step: "settle")

    post send_invoice_api_v1_invoice_path(id: invoice.id), params: { invoice_email: }, headers: auth_headers(user)

    expect(response).to have_http_status(:service_unavailable)
    expect(json_response["reason"]).to eq("ownership_moving")
    expect(enqueued_jobs).to be_empty
    expect(invoice.reload).to have_attributes(status: "draft", sent_at: nil)
  end

  it "leaves the invoice unsent when the mail cannot be queued" do
    delivery = double("invoice delivery")
    allow(delivery).to receive(:deliver_later).and_raise(IOError, "queue unavailable")
    allow(InvoiceMailer).to receive(:with).and_return(double("invoice mailer", send_invoice: delivery))

    expect {
      post send_invoice_api_v1_invoice_path(id: invoice.id), params: { invoice_email: }, headers: auth_headers(user)
    }.to raise_error(IOError, "queue unavailable")
    expect(invoice.reload).to have_attributes(status: "draft", sent_at: nil)
  end
end
