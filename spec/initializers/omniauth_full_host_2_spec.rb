# frozen_string_literal: true

require "rails_helper"

RSpec.describe OmniauthFullHost do
  let(:initializer_path) { Rails.root.join("config/initializers/omniauth_full_host.rb").to_s }

  around do |example|
    original_app_base_url = ENV["APP_BASE_URL"]
    original_full_host = OmniAuth.config.full_host
    example.run
  ensure
    ENV["APP_BASE_URL"] = original_app_base_url
    OmniAuth.config.full_host = original_full_host
  end

  # "Either production boot raises on an http:// APP_BASE_URL (checked by a spec), or a recorded
  # decision says plain http is allowed in production."
  it "refuses to boot in production on an http APP_BASE_URL" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
    ENV["APP_BASE_URL"] = "http://app.miru.so"
    OmniAuth.config.full_host = nil

    expect { load initializer_path }.to raise_error(OmniauthFullHost::InvalidBaseUrl)
    expect(OmniAuth.config.full_host).to be_nil
  end
end
