# frozen_string_literal: true

# Moves the entries id sequence above a given id, and never back
# (docs/architecture/timekeeping-soa.md section 10.3).
class Timekeeping::Internal::V1::Handoff::EntryIdSequencesController < Timekeeping::Internal::V1::Handoff::BaseController
  def create
    above = json_body["above"]
    # A JSON string or a negative number is refused, not converted: Integer()
    # would accept "3", and no entry id is negative.
    return render_invalid_request unless above.is_a?(Integer) && !above.negative?

    render json: { next_id: service_store.advance_entry_id_sequence(above:) }
  end
end
