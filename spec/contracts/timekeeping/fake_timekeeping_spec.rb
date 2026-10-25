# frozen_string_literal: true

require "rails_helper"
require_relative "entry_api_examples"
require_relative "idempotency_examples"
require_relative "reservations_examples"

# Each group runs in its own context, with nothing from the other groups, to
# show a provider can run one group before the others exist.
RSpec.describe TimekeepingContract::FakeTimekeeping do
  include_context "timekeeping contract fakes"

  describe "the entry API contract alone" do
    it_behaves_like "timekeeping entry API contract"
  end

  describe "the reservations contract alone" do
    it_behaves_like "timekeeping reservations contract"
  end

  describe "the idempotency contract for entries and reservations" do
    it_behaves_like "timekeeping idempotency contract", contracts: [:entry_api, :reservations]
  end
end
