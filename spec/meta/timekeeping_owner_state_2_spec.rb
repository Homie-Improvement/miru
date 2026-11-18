# frozen_string_literal: true

require "rails_helper"
require "pg"

RSpec.describe "TimekeepingDatabaseReset.reset! without a database" do
  it "reset! does nothing when TIMEKEEPING_DATABASE_URL is unset and refuses an unknown state" do
    # "`reset!` does nothing when `TIMEKEEPING_DATABASE_URL` is unset or the database does not exist yet."
    expect(PG).not_to receive(:connect)
    [nil, "legacy", "timekeeping", "rollback"].each do |state|
      expect(TimekeepingDatabaseReset.reset!(state, env: {})).to be_nil
    end

    expect do
      TimekeepingDatabaseReset.reset!("bogus", env: { "TIMEKEEPING_DATABASE_URL" => "dbname=timekeeping_test" })
    end.to raise_error(ArgumentError)
  end
end
