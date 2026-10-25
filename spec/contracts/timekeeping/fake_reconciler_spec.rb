# frozen_string_literal: true

require "rails_helper"
require_relative "prepare_reconciliation_examples"

RSpec.describe TimekeepingContract::FakeReconciler do
  include_context "timekeeping contract fakes"

  it_behaves_like "timekeeping prepare reconciliation"
end
