# frozen_string_literal: true

require "rails_helper"

RSpec.describe AnalyticsMailer, type: :mailer do
  describe "#threshold_alert" do
    let(:company) { create(:company, name: "Acme Analytics") }
    let(:recipient) { create(:user, email: "owner@example.com") }

    it "renders the analytics threshold email" do
      mail = described_class.with(
        company_id: company.id,
        recipient: recipient.email,
        alert: {
          type: "low_utilization",
          title: "Low utilization detected",
          message: "Team utilization is below 60% for the previous completed week.",
          metadata: { utilization_rate: 55.0, total_hours: 20.0, billable_hours: 11.0 }
        }
      ).threshold_alert

      body = mail.html_part&.body&.decoded || mail.body.decoded

      expect(mail.to).to eq([recipient.email])
      expect(mail.subject).to include("Acme Analytics")
      expect(body).to include("Low utilization detected")
      expect(body).to include("55.0")
      expect(body).to include("20.0")
      expect(body).to include("View analytics")
    end
  end
end

RSpec.describe AnalyticsMailer, type: :mailer do
  # "app/services/quick_books/configuration.rb, app/mcp/api_proxy.rb and the mailers no longer carry their own
  # APP_BASE_URL fallback literals; each reads the one per-environment base URL (APP_BASE_URL, else config.x.default_base_url)."
  it "links the analytics email to the swapped config.x.default_base_url when APP_BASE_URL is unset" do
    original_app_base_url = ENV["APP_BASE_URL"]
    original_default_base_url = Rails.configuration.x.default_base_url
    ENV.delete("APP_BASE_URL")
    Rails.configuration.x.default_base_url = "https://boot-check.test"
    company = create(:company, name: "Acme Analytics")
    recipient = create(:user, email: "owner@example.com")

    mail = described_class.with(
      company_id: company.id,
      recipient: recipient.email,
      alert: {
        type: "low_utilization",
        title: "Low utilization detected",
        message: "Team utilization is below 60% for the previous completed week.",
        metadata: { utilization_rate: 55.0, total_hours: 20.0, billable_hours: 11.0 }
      }
    ).threshold_alert
    body = mail.html_part&.body&.decoded || mail.body.decoded

    expect(body).to include("https://boot-check.test/reports")
    expect(body).not_to include('href="/reports"')
  ensure
    original_app_base_url.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original_app_base_url
    Rails.configuration.x.default_base_url = original_default_base_url
  end
end

RSpec.describe AnalyticsMailer, type: :mailer do
  let(:company) { create(:company, name: "Acme Analytics") }
  let(:recipient) { create(:user, email: "owner@example.com") }

  # Acceptance: "the mailers no longer carry their own APP_BASE_URL fallback literals; each reads
  # the one per-environment base URL (APP_BASE_URL, else config.x.default_base_url)."
  it "links to the configured base URL, not a relative or blank-prefixed path, when APP_BASE_URL is whitespace" do
    original_app_base_url = ENV["APP_BASE_URL"]
    original_default_base_url = Rails.configuration.x.default_base_url
    ENV["APP_BASE_URL"] = "   "
    Rails.configuration.x.default_base_url = "https://boot-check.test"

    mail = described_class.with(
      company_id: company.id,
      recipient: recipient.email,
      alert: {
        type: "low_utilization",
        title: "Low utilization detected",
        message: "Team utilization is below 60% for the previous completed week.",
        metadata: { utilization_rate: 55.0, total_hours: 20.0, billable_hours: 11.0 }
      }
    ).threshold_alert
    body = mail.html_part&.body&.decoded || mail.body.decoded

    expect(body).to include("https://boot-check.test/reports")
    expect(body).not_to include("href=\"/reports\"")
    expect(body).not_to include("   /reports")
  ensure
    original_app_base_url.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original_app_base_url
    Rails.configuration.x.default_base_url = original_default_base_url
  end
end
