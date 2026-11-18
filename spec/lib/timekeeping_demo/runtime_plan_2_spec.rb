# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimekeepingDemo::RuntimePlan do
  it "refuses to build when both applications would connect as the same database user" do
    procfile = Rails.root.join("Procfile.timekeeping").read
    credentials = TimekeepingDemo::Credentials.generate

    # "In the local demo each application reads these keys from its own process environment, and the two applications share no database credential."
    shared_by_url = {
      "DATABASE_URL" => "postgres://shared_user:pw@127.0.0.1:5432/miru_demo",
      "TIMEKEEPING_DATABASE_URL" => "postgres://shared_user:pw@127.0.0.1:5432/timekeeping_demo"
    }
    shared_by_db_user = {
      "DB_USER" => "shared_user",
      "DB_PASS" => "pw",
      "TIMEKEEPING_DATABASE_URL" => "postgres://shared_user:pw@127.0.0.1:5432/timekeeping_demo"
    }

    [shared_by_url, shared_by_db_user].each do |caller_env|
      expect do
        described_class.build(root: Rails.root.to_s, procfile:, caller_env:, credentials:,
                              ports: { monolith: 3000, timekeeping: 3100 })
      end.to raise_error(TimekeepingDemo::ConfigurationError)
    end
  end
end
