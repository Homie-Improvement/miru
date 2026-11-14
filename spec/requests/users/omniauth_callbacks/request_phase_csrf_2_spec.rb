# frozen_string_literal: true

require "rails_helper"

RSpec.describe "OmniAuth advisory floor" do
  # The advisory reads: "Name: omniauth Version: 2.1.4 CVE: CVE-2026-63183 Title: OmniAuth - Host Header Injection Vulnerability Solution: update to '>= 2.2.0'"
  it "CVE-2026-63183: omniauth is at least 2.2.0" do
    expect(Gem.loaded_specs["omniauth"].version).to be >= Gem::Version.new("2.2.0")
  end
end
