# frozen_string_literal: true

require "rails_helper"

RSpec.describe InvoiceMailer, type: :mailer do
  describe "invoice" do
    let(:company) { create :company }
    let(:client) { create :client, company: }
    let(:invoice) { create :invoice, client:, company:, status: :sending }
    let(:recipients) { [invoice.client.email, "miru@example.com"] }
    let(:subject) { "Invoice (#{invoice.invoice_number}) due on #{invoice.due_date}" }
    let(:mail) { InvoiceMailer.with(invoice_id: invoice.id, subject:, recipients:).invoice }

    it "renders the headers" do
      expect(mail.subject).to eq(subject)
      expect(mail.to).to eq(recipients)
    end

    it "renders the body" do
      expect(mail.body.encoded).to include("Invoice ready to review")
      expect(mail.body.encoded).to include(invoice.invoice_number)
    end

    context "when the company has a logo" do
      let(:company) { create :company, :with_logo, name: "Saeloun Logo Co" }

      it "renders the organization logo instead of attaching Miru fallback logos" do
        body = mail.html_part.body.decoded

        expect(body).to include('alt="Saeloun Logo Co"')
        expect(body).to match(/src="cid:[^"]+/)

        company_logo_attachment = mail.attachments.find { |a| a.filename&.start_with?("company_logo_#{company.id}") }
        expect(company_logo_attachment).to be_present
        expect(company_logo_attachment.content_type).to match(/image/)
        expect(company_logo_attachment["content-disposition"].to_s).to include("inline")

        expect(mail.attachments["MiruLogoDarkWithText.png"]).to be_nil
        expect(mail.attachments["MiruLogoLightWithText.png"]).to be_nil
      end

      it "keeps the PDF logo URL separate from the inline email attachment URL" do
        expect(InvoicePayment::PdfGeneration).to receive(:process) do |generated_invoice, logo_url, root_url|
          expect(generated_invoice).to eq(invoice)
          expect(logo_url).to include("test-image.png")
          expect(logo_url).not_to start_with("cid:")
          expect(root_url).to be_present

          "%PDF-1.4 invoice"
        end

        body = mail.html_part.body.decoded

        expect(body).to match(/src="cid:[^"]+/)
      end
    end

    context "with notification preferences" do
      let(:admin_user) { create(:user, current_workspace_id: company.id) }

      before { admin_user.add_role(:admin, company) }

      context "when invoice notifications are enabled" do
        let!(:notification_preference) do
          create(:notification_preference,
            user: admin_user,
            company:,
            invoice_email_notifications: true,
            unsubscribed_from_all: false
          )
        end

        it "should send invoice emails" do
          expect(mail.to).to include(invoice.client.email)
          expect(mail.subject).to include("Invoice")
        end
      end

      context "when invoice notifications are disabled" do
        let!(:notification_preference) do
          create(:notification_preference,
            user: admin_user,
            company:,
            invoice_email_notifications: false,
            unsubscribed_from_all: false
          )
        end

        it "documents that filtering should happen at service level" do
          # The mailer itself doesn't check preferences
          # The service calling the mailer should check: notification_preference.invoice_email_notifications
          expect(mail.to).to eq(recipients)
        end
      end

      context "when user is unsubscribed from all" do
        let!(:notification_preference) do
          create(:notification_preference,
            user: admin_user,
            company:,
            invoice_email_notifications: true,
            unsubscribed_from_all: true
          )
        end

        it "documents that unsubscribed users should not receive internal notifications" do
          # Client should still receive the invoice
          # Internal notifications should be filtered by the service
          expect(mail.to).to include(invoice.client.email)
          # The service should check: notification_preference.unsubscribed_from_all
        end
      end
    end
  end

  describe "send_invoice" do
    let(:company) { create :company }
    let(:client) { create :client, company: }
    let(:invoice) { create :invoice, client:, company: }
    let(:recipients) { [invoice.client.email] }
    let(:subject) { "Invoice #{invoice.invoice_number} from #{company.name}" }
    let(:mail) do
      InvoiceMailer.with(
        invoice:,
        recipients:,
        subject:,
        pdf_data: "%PDF-1.4 preview"
      ).send_invoice
    end

    it "uses the application mailer sender instead of a noreply fallback" do
      default_from = Mail::Address.new(ApplicationMailer.default[:from])
      expect(mail.from).to eq([default_from.address])
      expect(mail[:from].display_names).to include(default_from.display_name)
      expect(mail.from).not_to eq(["noreply@example.com"])
      expect(mail.subject).to eq(subject)
      expect(mail.to).to eq(recipients)
    end
  end
end

# Generated by Descant: acceptance tests below.

RSpec.describe InvoiceMailer, type: :mailer do
  # Acceptance bar: "Every invoice, line-item, invoice-tax and payment write, mobile-collection payments included,
  # gets 503 ownership_moving while handoff_step is set and writes nothing"
  # The mailer writes sent_at with update_columns and then the sent status; a refusal between them
  # would leave a half-written invoice.
  it "leaves sent_at and status untouched when an invoice mail is processed during a handoff" do
    company = create(:company)
    client = create(:client, company:)
    invoice = create(:invoice, client:, company:, status: :sending)
    allow(InvoicePayment::PdfGeneration).to receive(:process).and_return("%PDF-1.4 invoice")
    invoice.reload
    expect(invoice.sent_at).to be_nil
    expect(invoice.status).to eq("sending")
    TimekeepingOwnership.current.update!(handoff_step: "close_admission")
    ActionMailer::Base.deliveries.clear

    expect do
      InvoiceMailer.with(invoice_id: invoice.id, subject: "Invoice", recipients: [client.email]).invoice.deliver_now
    end.to raise_error(Timekeeping::BillingFence::OwnershipMoving)

    invoice.reload
    expect(invoice.sent_at).to be_nil
    expect(invoice.status).to eq("sending")
    expect(ActionMailer::Base.deliveries).to be_empty
  end

  # "`InvoiceMailer#update_status` calls `Invoices::ReservationBoundary.mark_billed(invoice)` in place of `update_timesheet_entry_status!`"
  it "sending an invoice mail marks its entries billed through the reservation boundary" do
    company = create(:company)
    client = create(:client, company:)
    project = create(:project, client:, billable: true)
    owner = create(:user, current_workspace_id: company.id)
    entry = create(:timesheet_entry, user: owner, project:, bill_status: "unbilled")
    invoice = create(:invoice, client:, company:, status: :sending)
    create(:invoice_line_item, invoice:, timesheet_entry: entry, rate: 100, quantity: 60)
    allow(InvoicePayment::PdfGeneration).to receive(:process).and_return("%PDF-1.4 invoice")
    allow(Invoices::ReservationBoundary).to receive(:mark_billed).and_call_original

    InvoiceMailer.with(invoice_id: invoice.id, subject: "Invoice", recipients: [client.email]).invoice.deliver_now

    expect(Invoices::ReservationBoundary).to have_received(:mark_billed).once
    expect(entry.reload.bill_status).to eq("billed")
    expect(Invoice.method_defined?(:update_timesheet_entry_status!)).to be(false)
  end
end

RSpec.describe InvoiceMailer, "refused billing under the prepared owner", type: :mailer do
  # The prepared store refuses to bill an entry whose stored snapshot the
  # projection would reject; the invoice must then stay unsent rather than go
  # out with its work still showing as unbilled.
  it "raises the refusal, leaves the invoice unsent and delivers no mail when its entry cannot be billed" do
    company = create(:company)
    client = create(:client, company:)
    project = create(:project, client:, billable: true)
    owner = create(:user, current_workspace_id: company.id)
    entry = create(:timesheet_entry, user: owner, project:, bill_status: "unbilled")
    invoice = create(:invoice, client:, company:, status: :sending)
    create(:invoice_line_item, invoice:, timesheet_entry: entry, rate: 100, quantity: 60)
    stored = Timekeeping::LocalEntry.create!(id: entry.id, company_id: company.id, user_id: owner.id, project_id: project.id,
                                             work_date: entry.work_date, duration: 60.0, bill_status: "unbilled")
    stored.update_columns(source: "legacy")
    TimekeepingOwnership.current.update!(owner: "monolith", monolith_store: "prepared", handoff_step: nil)
    allow(InvoicePayment::PdfGeneration).to receive(:process).and_return("%PDF-1.4 invoice")
    ActionMailer::Base.deliveries.clear

    expect do
      InvoiceMailer.with(invoice_id: invoice.id, subject: "Invoice", recipients: [client.email]).invoice.deliver_now
    end.to raise_error(Invoices::OperationErrors::Refused) { |error|
      expect(error.outcome.conflicts).to eq([{ entry_id: entry.id, reason: "unpublishable_entry" }])
    }

    invoice.reload
    expect(invoice.status).to eq("sending")
    expect(invoice.sent_at).to be_nil
    expect(stored.reload.bill_status).to eq("unbilled")
    expect(ActionMailer::Base.deliveries).to be_empty
  end
end

RSpec.describe InvoiceMailer, "unsettled billing under the timekeeping owner", type: :mailer do
  # A Timekeeping outage while billing must keep the invoice unsent, so the
  # client is never mailed an invoice whose work is still open for billing.
  it "leaves the invoice unsent with no mail when mark_billed gets a 503, and a retried send bills the entry once" do
    company = create(:company)
    client = create(:client, company:)
    project = create(:project, client:, billable: true)
    owner = create(:user, current_workspace_id: company.id)
    entry = create(:timesheet_entry, user: owner, project:, bill_status: "unbilled")
    invoice = create(:invoice, client:, company:, status: :sending)
    create(:invoice_line_item, invoice:, timesheet_entry: entry, rate: 100, quantity: 60)
    TimekeepingOwnership.current.update!(owner: "timekeeping", handoff_step: nil)

    fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
    fake.generation = TimekeepingOwnership.current.generation
    fake.add_entry(company_id: company.id, user_id: owner.id, project_id: project.id, id: entry.id)
    fake.add_reservation(entry_id: entry.id, invoice_id: invoice.id, state: "committed", disposition: "active")
    # The monolith's record of that settled reservation.
    InvoiceEntryHolding.create!(company_id: company.id, invoice_id: invoice.id, entry_ids: [entry.id], disposition: "active")
    forward = TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil)
    outage = { mark_billed: true }
    http = Object.new
    http.define_singleton_method(:call) do |method, path, headers: {}, body: nil|
      if outage[:mark_billed] && path.end_with?("/mark-billed")
        next TimekeepingContract::Response.new(status: 503, body: { "reason" => "unavailable" })
      end

      forward.call(method, path, headers:, body:)
    end
    use_fake_timekeeping_reservations(fake, http:)
    allow(InvoicePayment::PdfGeneration).to receive(:process).and_return("%PDF-1.4 invoice")
    ActionMailer::Base.deliveries.clear
    send_mail = -> { InvoiceMailer.with(invoice_id: invoice.id, subject: "Invoice", recipients: [client.email]).invoice.deliver_now }

    expect(&send_mail).to raise_error(Invoices::OperationErrors::BillingRetryable)

    invoice.reload
    expect(invoice.status).to eq("sending")
    expect(invoice.sent_at).to be_nil
    expect(ActionMailer::Base.deliveries).to be_empty
    expect(fake.stored_entry(entry.id)["bill_status"]).to eq("unbilled")

    outage[:mark_billed] = false
    send_mail.call

    expect(invoice.reload.status).to eq("sent")
    expect(ActionMailer::Base.deliveries.size).to eq(1)
    expect(fake.stored_entry(entry.id)["bill_status"]).to eq("billed")
    expect(fake.requests.count { |request| request[:path].end_with?("/mark-billed") }).to eq(1)
  end

  # A sending invoice that gains an entry under the timekeeping owner gets no
  # holding and no remote reservation, so Timekeeping would bill nothing.
  it "refuses to send, with no mail and nothing billed, an invoice whose entry was added without a holding" do
    company = create(:company)
    client = create(:client, company:)
    project = create(:project, client:, billable: true)
    owner = create(:user, current_workspace_id: company.id)
    entry = create(:timesheet_entry, user: owner, project:, bill_status: "unbilled")
    invoice = create(:invoice, client:, company:, status: :sending)
    TimekeepingOwnership.current.update!(owner: "timekeeping", handoff_step: nil)

    fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
    fake.generation = TimekeepingOwnership.current.generation
    fake.add_entry(company_id: company.id, user_id: owner.id, project_id: project.id, id: entry.id)
    use_fake_timekeeping_reservations(fake)
    create(:invoice_line_item, invoice:, timesheet_entry: entry, rate: 100, quantity: 60)
    expect(InvoiceEntryHolding.where(company_id: company.id, invoice_id: invoice.id)).to be_empty
    allow(InvoicePayment::PdfGeneration).to receive(:process).and_return("%PDF-1.4 invoice")
    ActionMailer::Base.deliveries.clear

    expect do
      InvoiceMailer.with(invoice_id: invoice.id, subject: "Invoice", recipients: [client.email]).invoice.deliver_now
    end.to raise_error(Invoices::OperationErrors::Refused)

    expect(invoice.reload.status).to eq("sending")
    expect(ActionMailer::Base.deliveries).to be_empty
    expect(fake.stored_entry(entry.id)["bill_status"]).to eq("unbilled")
    expect(fake.requests.count { |request| request[:path].end_with?("/mark-billed") }).to eq(0)
  end

  it "keeps sending unchanged under the legacy owner" do
    company = create(:company)
    client = create(:client, company:)
    project = create(:project, client:, billable: true)
    owner = create(:user, current_workspace_id: company.id)
    entry = create(:timesheet_entry, user: owner, project:, bill_status: "unbilled")
    invoice = create(:invoice, client:, company:, status: :sending)
    create(:invoice_line_item, invoice:, timesheet_entry: entry, rate: 100, quantity: 60)
    allow(InvoicePayment::PdfGeneration).to receive(:process).and_return("%PDF-1.4 invoice")
    ActionMailer::Base.deliveries.clear

    InvoiceMailer.with(invoice_id: invoice.id, subject: "Invoice", recipients: [client.email]).invoice.deliver_now

    expect(invoice.reload.status).to eq("sent")
    expect(entry.reload.bill_status).to eq("billed")
    expect(ActionMailer::Base.deliveries.size).to eq(1)
  end
end
