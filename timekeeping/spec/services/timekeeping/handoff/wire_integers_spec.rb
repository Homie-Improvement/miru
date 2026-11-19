# frozen_string_literal: true

require "rails_helper"
require "bigdecimal"

RSpec.describe Timekeeping::Handoff::WireIntegers do
  # "`generation` must be a positive integer and `through` a non-negative one. A missing, negative or
  # non-integer value gets a refusal reason from timekeeping/app/services/timekeeping/reasons.rb and changes nothing."
  it "accepts only a positive Integer generation and a non-negative Integer position, refusing strings, decimals, booleans and nil" do
    malformed = [nil, "3", 3.5, 3.0, BigDecimal("3"), true, false, -1, [3], { "n" => 3 }]

    expect(malformed.map { |value| described_class.generation?(value) }).to all(be(false))
    expect(malformed.map { |value| described_class.position?(value) }).to all(be(false))

    expect(described_class.generation?(0)).to be(false)
    expect(described_class.generation?(1)).to be(true)
    expect(described_class.generation?(7)).to be(true)

    expect(described_class.position?(0)).to be(true)
    expect(described_class.position?(42)).to be(true)
    expect(described_class.position?(2**64)).to be(true)
  end
end
