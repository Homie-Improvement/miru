# frozen_string_literal: true

module Timekeeping
  # Stands in for Timekeeping::LocalOwner, which Timekeeping::Gateway takes as
  # local_owner:. It records every call with its keywords and writes nothing,
  # so a spec can show the prepared branch went only here and what it sent.
  # Every call answers the outcome given at construction.
  class FakeLocalOwner
    attr_reader :calls

    def initialize(outcome: LocalOwner::Outcome.new(status: 200, body: {}))
      @outcome = outcome
      @calls = []
    end

    def call(**kwargs)
      @calls += [{ method: :call, kwargs: }]
      @outcome
    end
  end
end
