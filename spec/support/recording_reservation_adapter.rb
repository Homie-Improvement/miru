# frozen_string_literal: true

# A reservation adapter for specs. Each verb is scripted with either a
# ReservationOutcome to return or a callable that receives the request (to
# raise, block or answer per call). Every request any verb receives is
# recorded in order, so a spec can read what reached the reservation port.
class RecordingReservationAdapter
  attr_reader :requests

  def initialize(prepare:, commit:, abort:)
    @answers = { prepare:, commit:, abort: }.freeze
    @requests = []
  end

  def prepare(request) = answer(:prepare, request)

  def commit(request) = answer(:commit, request)

  def abort(request) = answer(:abort, request)

  private

    def answer(verb, request)
      @requests << request
      scripted = @answers.fetch(verb)
      scripted.respond_to?(:call) ? scripted.call(request) : scripted
    end
end
