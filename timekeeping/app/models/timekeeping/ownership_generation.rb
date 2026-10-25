# frozen_string_literal: true

module Timekeeping
  # The current ownership generation of one company. Every statement names a
  # single company_id, so one company's ownership change never touches another
  # company's row or makes its writes stale.
  class OwnershipGeneration < ApplicationRecord
    self.table_name = "ownership_generations"
    self.primary_key = "company_id"

    # Sets this company's generation, creating its row when there is none.
    def self.advance(company_id:, generation:)
      upsert({ company_id:, generation: }, unique_by: :company_id)
    end
  end
end
