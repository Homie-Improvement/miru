# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Internal reference routing", type: :routing do
  it "routes the company reference to the companies references controller" do
    expect(get: "/internal/v1/companies/1/reference").to route_to(
      controller: "internal/v1/companies/references",
      action: "show",
      company_id: "1",
      format: "json"
    )
  end
end
