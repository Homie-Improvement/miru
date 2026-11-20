# frozen_string_literal: true

require "rails_helper"

RSpec.describe IntegratedRuntime, "after the URL guard moved to TestDatabaseGuard" do
  # "IntegratedRuntime no longer defines `require_test_database_url!` or `active_record_database_name` and calls the TestDatabaseGuard method instead"
  it "IntegratedRuntime no longer defines require_test_database_url! or active_record_database_name" do
    expect(described_class.respond_to?(:require_test_database_url!, true)).to be(false)
    expect(described_class.respond_to?(:active_record_database_name, true)).to be(false)
    expect(TestDatabaseGuard).to respond_to(:require_test_database_url!)
  end
end
