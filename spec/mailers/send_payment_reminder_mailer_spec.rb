# frozen_string_literal: true

require "rails_helper"

RSpec.describe SendPaymentReminderMailer, type: :mailer do
  describe "send_payment_reminder" do
    let(:company) { create :company }
    let(:client) { create :client, company: }
    let(:invoice) { create :invoice, client:, company:, status: "overdue" }
    let(:recipients) { [invoice.client.email, "miru@example.com"] }
    let(:subject) { "Reminder to complete payments for unpaid invoices" }
    let(:message) {
      "This is a gentle reminder to complete payments for the following invoices. " \
      "You can find the respective payment links along with the invoice details given below"
    }
    let(:mail) {
      SendPaymentReminderMailer.with(
        client_id: client.id,
        selected_invoices: [invoice.id],
        subject:,
        recipients:,
        message:
      ).send_payment_reminder
    }
    let(:body) { mail.html_part&.body&.decoded || mail.body.decoded }

    it "renders the headers" do
      expect(mail.subject).to eq(subject)
      expect(mail.to).to eq(recipients)
    end

    it "renders the body" do
      expect(body).to include("Payment reminder")
      expect(body).to include(invoice.invoice_number)
      expect(body).to include("Open invoice")
      expect(body).to include("Amount due")
    end

    it "rejects invoices from another client" do
      other_invoice = create(:invoice)
      foreign_mail = SendPaymentReminderMailer.with(
        client_id: client.id,
        selected_invoices: [other_invoice.id],
        recipients:,
        message:
      ).send_payment_reminder

      expect { foreign_mail.body }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end

RSpec.describe SendPaymentReminderMailer, "base URL", type: :mailer do
  # "each reads the one per-environment base URL (APP_BASE_URL, else config.x.default_base_url)."
  it "links each reminded invoice to the swapped config.x.default_base_url when APP_BASE_URL is unset" do
    with_app_base_url(env: nil, default: "https://boot-check.test") do
      company = create(:company)
      client = create(:client, company:)
      invoice = create(:invoice, client:, company:, status: "overdue")

      mail = SendPaymentReminderMailer.with(
        client_id: client.id,
        selected_invoices: [invoice.id],
        subject: "Reminder",
        recipients: [client.email],
        message: "Please pay"
      ).send_payment_reminder
      body = mail.html_part&.body&.decoded || mail.body.decoded

      expect(body).to include("https://boot-check.test/invoices/#{invoice.external_view_key}/view")
    end
  end
end
