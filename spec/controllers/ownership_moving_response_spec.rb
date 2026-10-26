# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationController, "ownership_moving refusal", type: :controller do
  controller do
    skip_before_action :authenticate_user!, raise: false
    skip_after_action :verify_authorized, raise: false

    def index
      raise Timekeeping::BillingFence::OwnershipMoving
    end
  end

  it "renders an HTML error page with status 503 for a browser page" do
    get :index, format: :html

    expect(response).to have_http_status(:service_unavailable)
    expect(response.media_type).to eq("text/html")
    expect(response.headers["Retry-After"]).to eq(Timekeeping::BillingFence::RETRY_AFTER_SECONDS.to_s)
  end

  it "renders the JSON refusal for a JSON caller" do
    get :index, format: :json

    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body["reason"]).to eq("ownership_moving")
    expect(response.headers["Retry-After"]).to eq(Timekeeping::BillingFence::RETRY_AFTER_SECONDS.to_s)
  end
end
