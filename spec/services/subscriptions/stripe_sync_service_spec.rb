# frozen_string_literal: true

require "rails_helper"

RSpec.describe Subscriptions::StripeSyncService do
  describe ".process" do
    let(:company) { create(:company, plan_tier: "free") }

    it "updates the company from an active Stripe subscription" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("PLAN_PURCHASE_ALERT_EMAIL").and_return("vipul@saeloun.com")

      subscription = OpenStruct.new(
        id: "sub_123",
        customer: "cus_123",
        status: "active",
        current_period_end: Time.zone.local(2026, 4, 10, 12, 0, 0).to_i,
        items: OpenStruct.new(
          data: [
            OpenStruct.new(
              price: OpenStruct.new(
                recurring: OpenStruct.new(interval: "month")
              )
            )
          ]
        )
      )

      expect do
        expect do
          result = described_class.process(company:, subscription:, notify_plan_purchase: true)

          expect(result).to eq(true)
        end.to have_enqueued_mail(SubscriptionMailer, :plan_purchased)
      end.to change { Ahoy::Event.where(name: "subscription_purchased").count }.by(1)

      expect(company.reload.plan_tier).to eq("paid")
      expect(company.stripe_customer_id).to eq("cus_123")
      expect(company.stripe_subscription_id).to eq("sub_123")
      expect(company.subscription_status).to eq("active")
      expect(company.subscription_interval).to eq("month")
      expect(company.subscription_ends_at).to eq(Time.zone.local(2026, 4, 10, 12, 0, 0))
      expect(Ahoy::Event.where(name: "subscription_purchased").last.properties).to include(
        "company_id" => company.id,
        "subscription_id" => "sub_123",
        "subscription_status" => "active",
        "billing_interval" => "monthly",
        "seat_quantity" => 1
      )
    end

    it "updates the company from a hash-like Stripe subscription payload" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("PLAN_PURCHASE_ALERT_EMAIL").and_return("vipul@saeloun.com")
      allow(ENV).to receive(:[]).with("APP_BASE_URL").and_return("https://app.miru.so")

      subscription = {
        "id" => "sub_hash_123",
        "customer" => "cus_hash_123",
        "status" => "active",
        "current_period" => {
          "end" => Time.zone.local(2026, 5, 10, 12, 0, 0).to_i
        },
        "items" => {
          "data" => [
            {
              "price" => {
                "recurring" => {
                  "interval" => "year"
                }
              }
            }
          ]
        }
      }

      expect do
        result = described_class.process(company:, subscription:, notify_plan_purchase: true)

        expect(result).to eq(true)
      end.to have_enqueued_mail(SubscriptionMailer, :plan_purchased)

      expect(company.reload.plan_tier).to eq("paid")
      expect(company.stripe_customer_id).to eq("cus_hash_123")
      expect(company.stripe_subscription_id).to eq("sub_hash_123")
      expect(company.subscription_status).to eq("active")
      expect(company.subscription_interval).to eq("year")
      expect(company.subscription_ends_at).to eq(Time.zone.local(2026, 5, 10, 12, 0, 0))
    end

    it "does not email again when an already-paid subscription refreshes" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("PLAN_PURCHASE_ALERT_EMAIL").and_return("vipul@saeloun.com")

      company.update!(
        plan_tier: "paid",
        stripe_customer_id: "cus_123",
        stripe_subscription_id: "sub_123",
        subscription_status: "active",
        subscription_interval: "month"
      )

      subscription = OpenStruct.new(
        id: "sub_123",
        customer: "cus_123",
        status: "active",
        current_period_end: Time.zone.local(2026, 4, 10, 12, 0, 0).to_i,
        items: OpenStruct.new(
          data: [
            OpenStruct.new(
              price: OpenStruct.new(
                recurring: OpenStruct.new(interval: "month")
              )
            )
          ]
        )
      )

      expect {
        expect do
          result = described_class.process(company:, subscription:, notify_plan_purchase: true)

          expect(result).to eq(true)
        end.not_to have_enqueued_mail(SubscriptionMailer, :plan_purchased)
      }.not_to change { Ahoy::Event.where(name: "subscription_purchased").count }
    end

    it "skips the alert when no alert email is configured" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("PLAN_PURCHASE_ALERT_EMAIL").and_return(nil)

      subscription = OpenStruct.new(
        id: "sub_123",
        customer: "cus_123",
        status: "active",
        current_period_end: Time.zone.local(2026, 4, 10, 12, 0, 0).to_i,
        items: OpenStruct.new(
          data: [
            OpenStruct.new(
              price: OpenStruct.new(
                recurring: OpenStruct.new(interval: "month")
              )
            )
          ]
        )
      )

      expect(Rails.logger).to receive(:warn).with(/PLAN_PURCHASE_ALERT_EMAIL/)

      expect do
        result = described_class.process(company:, subscription:, notify_plan_purchase: true)

        expect(result).to eq(true)
      end.not_to have_enqueued_mail(SubscriptionMailer, :plan_purchased)
    end

    it "does not send a purchase alert for generic subscription reconciliation" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("PLAN_PURCHASE_ALERT_EMAIL").and_return("vipul@saeloun.com")

      subscription = OpenStruct.new(
        id: "sub_123",
        customer: "cus_123",
        status: "active",
        current_period_end: Time.zone.local(2026, 4, 10, 12, 0, 0).to_i,
        items: OpenStruct.new(
          data: [
            OpenStruct.new(
              price: OpenStruct.new(
                recurring: OpenStruct.new(interval: "month")
              )
            )
          ]
        )
      )

      expect do
        result = described_class.process(company:, subscription:)

        expect(result).to eq(true)
      end.not_to have_enqueued_mail(SubscriptionMailer, :plan_purchased)
    end

    it "revokes access when no subscription can be found" do
      company.update!(
        plan_tier: "paid",
        stripe_customer_id: "cus_123",
        stripe_subscription_id: "sub_123",
        subscription_status: "active",
        subscription_interval: "month"
      )

      allow(Stripe::Subscription).to receive(:retrieve).and_raise(Stripe::InvalidRequestError.new("missing", "id"))

      result = described_class.process(company:)

      expect(result).to eq(false)
      expect(company.reload.plan_tier).to eq("paid")
    end

    it "downgrades canceled subscriptions to free" do
      subscription = OpenStruct.new(
        id: "sub_123",
        customer: "cus_123",
        status: "canceled",
        current_period_end: nil,
        items: OpenStruct.new(
          data: [
            OpenStruct.new(
              price: OpenStruct.new(
                recurring: OpenStruct.new(interval: "year")
              )
            )
          ]
        )
      )

      result = described_class.process(company:, subscription:)

      expect(result).to eq(true)
      expect(company.reload.plan_tier).to eq("free")
      expect(company.subscription_status).to eq("canceled")
      expect(company.subscription_interval).to eq("year")
    end
  end
end

require "rails_helper"

RSpec.describe Subscriptions::StripeSyncService do
  include ActiveJob::TestHelper

  # app/services/subscriptions/stripe_sync_service.rb builds its URL (line 149) from AppBaseUrl.current instead of ENV['APP_BASE_URL'].
  # The service passes no billing_url; SubscriptionMailer#plan_purchased builds the link from
  # AppBaseUrl.current. This runs the real service and mailer so a raw ENV override fails it.
  it "sends the plan purchase alert with a billing link built from the config.x.default_base_url fallback when APP_BASE_URL is unset" do
    original_default = Rails.configuration.x.default_base_url
    original_env = ENV["APP_BASE_URL"]
    original_alert = ENV["PLAN_PURCHASE_ALERT_EMAIL"]
    ENV.delete("APP_BASE_URL")
    ENV["PLAN_PURCHASE_ALERT_EMAIL"] = "vipul@saeloun.com"
    Rails.configuration.x.default_base_url = "https://boot-check.test"
    ActionMailer::Base.deliveries.clear

    company = create(:company, plan_tier: "free")
    subscription = OpenStruct.new(
      id: "sub_base_url_123",
      customer: "cus_base_url_123",
      status: "active",
      current_period_end: Time.zone.local(2026, 4, 10, 12, 0, 0).to_i,
      items: OpenStruct.new(
        data: [
          OpenStruct.new(
            price: OpenStruct.new(recurring: OpenStruct.new(interval: "month"))
          )
        ]
      )
    )

    perform_enqueued_jobs do
      expect(described_class.process(company:, subscription:, notify_plan_purchase: true)).to eq(true)
    end

    mail = ActionMailer::Base.deliveries.find { |delivered| delivered.to.include?("vipul@saeloun.com") }
    expect(mail).to be_present
    expect(mail.html_part.body.decoded).to include("https://boot-check.test/settings/billing")
    expect(mail.text_part.body.decoded).to include("https://boot-check.test/settings/billing")
  ensure
    Rails.configuration.x.default_base_url = original_default
    original_env.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original_env
    original_alert.nil? ? ENV.delete("PLAN_PURCHASE_ALERT_EMAIL") : ENV["PLAN_PURCHASE_ALERT_EMAIL"] = original_alert
    ActionMailer::Base.deliveries.clear
  end
end
