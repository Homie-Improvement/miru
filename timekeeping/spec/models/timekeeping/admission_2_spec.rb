# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::Admission do
  include_context "timekeeping entry writes without transactional fixtures"

  # "The settling state survives a new connection"
  it "settling? holds when read on a new connection after begin_settling! commits" do
    described_class.fence!(lock_timeout: 1)
    described_class.begin_settling!(generation: 5)

    read_elsewhere = Thread.new { ApplicationRecord.connection_pool.with_connection { described_class.settling? } }.value

    expect(read_elsewhere).to be(true)
  end
end
