# frozen_string_literal: true

# A 409 stale_generation answer the projection gave one company's snapshots
# (docs/architecture/timekeeping-soa.md section 11.3). handoff_step is the
# step in progress when the refusal happened, nil outside a handoff; the
# alert task counts only those outside a handoff.
class TimekeepingStaleGenerationRefusal < ApplicationRecord
  validates :company_id, presence: true
  validates :handoff_step, inclusion: { in: TimekeepingOwnership::HANDOFF_STEPS }, allow_nil: true
end
