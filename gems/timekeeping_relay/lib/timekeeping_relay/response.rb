# frozen_string_literal: true

module TimekeepingRelay
  # An endpoint's answer to one batch. status is nil when no answer arrived
  # (a timeout or a transport failure); body is the parsed JSON, or whatever
  # else came back.
  Response = Data.define(:status, :body) do
    # Only a 200 that accounts for every snapshot in the batch counts as
    # delivered. A proxy page or a truncated answer can carry a 200 too, and
    # marking its rows sent would lose them.
    def delivered?(snapshot_count)
      return false unless status == 200 && body.is_a?(Hash)

      applied = body["applied"]
      ignored = body["ignored"]
      applied.is_a?(Integer) && ignored.is_a?(Integer) && applied + ignored == snapshot_count
    end
  end
end
