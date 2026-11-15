# frozen_string_literal: true

require "rails_helper"

RSpec.describe SendReminderMailer, type: :mailer do
  describe "send_reminder" do
    let(:company) { create :company }
    let(:client) { create :client, company: }
    let(:invoice) { create :invoice, client:, company: }
    let(:recipients) { [invoice.client.email, "miru@example.com"] }
    let(:subject) { "Reminder to complete payments for unpaid invoice (#{invoice.invoice_number})" }
    let(:mail) { SendReminderMailer.with(invoice:, subject:, recipients:).send_reminder }
    let(:body) { mail.html_part&.body&.decoded || mail.body.decoded }

    it "renders the headers" do
      expect(mail.subject).to eq(subject)
      expect(mail.to).to eq(recipients)
    end

    it "renders the body" do
      expect(body).to include("Payment reminder")
      expect(body).to include(invoice.invoice_number)
      expect(body).to include("is still awaiting payment")
      expect(body).to include("Open invoice")
    end

    context "when the company has a logo" do
      let(:company) { create :company, :with_logo, name: "Saeloun Logo Co" }

      it "uses a public logo URL for PDF generation and an inline logo in the email" do
        expect(InvoicePayment::PdfGeneration).to receive(:process) do |generated_invoice, logo_url, root_url|
          expect(generated_invoice).to eq(invoice)
          expect(logo_url).to include("test-image.png")
          expect(logo_url).not_to start_with("cid:")
          expect(root_url).to be_present

          "%PDF-1.4 reminder"
        end

        expect(body).to match(/src="cid:[^"]+/)
      end
    end
  end
end

RSpec.describe SendReminderMailer, "base URL", type: :mailer do
  # "each reads the one per-environment base URL (APP_BASE_URL, else config.x.default_base_url)."
  it "links the invoice reminder to the swapped config.x.default_base_url when APP_BASE_URL is unset" do
    with_app_base_url(env: nil, default: "https://boot-check.test") do
      company = create(:company)
      client = create(:client, company:)
      invoice = create(:invoice, client:, company:)

      mail = SendReminderMailer.with(invoice:, subject: "Reminder", recipients: [client.email]).send_reminder
      body = mail.html_part&.body&.decoded || mail.body.decoded

      expect(body).to include("https://boot-check.test/invoices/#{invoice.external_view_key}/view")
    end
  end
end
