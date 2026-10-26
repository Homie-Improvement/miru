# frozen_string_literal: true

# Writes the first cutover's correction snapshots, replacing any written
# before for the same entry and generation.
class Timekeeping::Internal::V1::Handoff::CorrectionSnapshotsController < Timekeeping::Internal::V1::Handoff::BaseController
  def update
    body = json_body
    written = Timekeeping::Handoff::CorrectionSnapshots.write!(
      snapshots: body["snapshots"], version: body["version"], generation: body["generation"]
    )
    render json: { written: }
  end
end
