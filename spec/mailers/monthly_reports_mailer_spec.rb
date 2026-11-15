# frozen_string_literal: true

require "rails_helper"

RSpec.describe MonthlyReportsMailer, type: :mailer do
  describe "cash_flow_digest" do
    let(:company) { create(:company, name: "Saeloun Inc", base_currency: "USD") }
    let(:user) { create(:user, email: "vipul@saeloun.com", current_workspace: company, locale: "en-US") }
    let(:client) { create(:client, company:, name: "Haul Hub Inc") }
    let(:invoice) { create(:invoice, company:, client:, status: :paid, amount: 50_644.17, currency: "USD") }
    let!(:payment) do
      create(
        :payment,
        invoice:,
        amount: 50_644.17,
        base_currency_amount: 50_644.17,
        transaction_date: Date.new(2026, 3, 12),
        transaction_type: :bank_transfer,
        status: :paid
      )
    end
    let!(:expense) do
      create(
        :expense,
        company:,
        user:,
        amount: 8_250.50,
        category_name: "Payroll",
        vendor_name: "Saeloun Payroll",
        date: Date.new(2026, 3, 15),
        status: :paid,
        paid_at: Time.zone.local(2026, 3, 15, 12, 0, 0)
      )
    end

    let(:mail) do
      described_class.with(
        company_id: company.id,
        recipient_id: user.id,
        month: "2026-03-01"
      ).cash_flow_digest
    end
    let(:body) { mail.html_part&.body&.decoded || mail.body.decoded }

    it "renders the headers" do
      expect(mail.to).to eq([user.email])
      expect(mail.subject).to eq("Saeloun Inc's March cash flow digest")
    end

    it "renders the body" do
      expect(body).to include("March cash flow digest")
      expect(body).to include("Top money-in sources")
      expect(body).to include("Haul Hub Inc")
      expect(body).to include("Saeloun Payroll")
      expect(body).to include("View reports in Miru")
    end
  end
end

RSpec.describe MonthlyReportsMailer, "base URL", type: :mailer do
  # "each reads the one per-environment base URL (APP_BASE_URL, else config.x.default_base_url)."
  it "links the cash flow digest to the swapped config.x.default_base_url reports page when APP_BASE_URL is unset" do
    with_app_base_url(env: nil, default: "https://boot-check.test") do
      company = create(:company, name: "Saeloun Inc", base_currency: "USD")
      user = create(:user, current_workspace: company, locale: "en-US")

      mail = described_class.with(company_id: company.id, recipient_id: user.id, month: "2026-03-01").cash_flow_digest
      body = mail.html_part&.body&.decoded || mail.body.decoded

      expect(body).to include("https://boot-check.test/reports")
    end
  end
end
