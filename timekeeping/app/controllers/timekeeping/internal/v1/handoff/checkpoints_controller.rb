# frozen_string_literal: true

# Exports Timekeeping's checkpoint tables and loads a checkpoint in their
# place. Both bodies are the checkpoint transport form, Checkpoint#to_json.
class Timekeeping::Internal::V1::Handoff::CheckpointsController < Timekeeping::Internal::V1::Handoff::BaseController
  def show
    render json: service_store.export_checkpoint.to_json
  end

  # Answers with the checkpoint read back from the loaded tables.
  def update
    render json: service_store.load_checkpoint(read_checkpoint).to_json
  end

  private

    # Checkpoint.from_json fetches keys and decodes values from whatever JSON
    # it is given, so a body of the wrong structure fails inside it with a
    # Ruby error. Each such error is a malformed request, not a server fault.
    def read_checkpoint
      Timekeeping::Handoff::Checkpoint.from_json(request.raw_post)
    rescue KeyError, TypeError, NoMethodError, ArgumentError => error
      raise Timekeeping::Handoff::Checkpoint::ShapeError, "unreadable checkpoint body: #{error.class}"
    end
end
