# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::Config do
  it "holds the service token and each configured credential, read on every call" do
    with_timekeeping_env(
      Timekeeping::Environment::SERVICE_TOKEN => "own-token",
      Timekeeping::Environment::SERVICE_CREDENTIALS => "first, second"
    ) do
      expect(Timekeeping.config.service_credentials).to eq(%w[own-token first second])
    end

    with_timekeeping_env(
      Timekeeping::Environment::SERVICE_TOKEN => "own-token",
      Timekeeping::Environment::SERVICE_CREDENTIALS => "third"
    ) do
      expect(Timekeeping.config.service_credentials).to eq(%w[own-token third])
    end
  end

  it "drops blank entries so an empty string never counts as a credential" do
    with_timekeeping_env(
      Timekeeping::Environment::SERVICE_TOKEN => nil,
      Timekeeping::Environment::SERVICE_CREDENTIALS => " ,,only, "
    ) do
      expect(Timekeeping.config.service_credentials).to eq(%w[only])
    end
  end
end
