# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::OwnershipGeneration do
  def generation_of(company_id)
    described_class.where(company_id:).pick(:generation)
  end

  describe ".advance" do
    it "creates the company's row when it has none" do
      described_class.advance(company_id: 41, generation: 3)

      expect(generation_of(41)).to eq(3)
    end

    it "updates the company's existing row" do
      described_class.advance(company_id: 41, generation: 3)
      described_class.advance(company_id: 41, generation: 4)

      expect(described_class.where(company_id: 41).count).to eq(1)
      expect(generation_of(41)).to eq(4)
    end

    it "leaves another company's row unchanged" do
      described_class.advance(company_id: 42, generation: 7)

      described_class.advance(company_id: 41, generation: 3)

      expect(generation_of(42)).to eq(7)
    end
  end
end
