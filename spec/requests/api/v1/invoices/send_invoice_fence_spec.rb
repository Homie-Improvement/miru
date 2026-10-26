# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Invoices#send_invoice during a Timekeeping handoff", type: :request do
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
    TimekeepingOwnership.current.update!(handoff_step: "settle")
  end

  it "answers 503 without queuing the client email or marking the invoice sent" do
    post send_invoice_api_v1_invoice_path(id: invoice.id), params: { invoice_email: }, headers: auth_headers(user)

    expect(response).to have_http_status(:service_unavailable)
    expect(json_response["reason"]).to eq("ownership_moving")
    expect(enqueued_jobs.map { |job| job["job_class"] || job[:job].to_s }).not_to include("ActionMailer::MailDeliveryJob")
    expect(invoice.reload).to have_attributes(status: "draft", sent_at: nil)
  end
end
