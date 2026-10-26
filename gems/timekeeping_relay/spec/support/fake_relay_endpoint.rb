# frozen_string_literal: true

require_relative "../../../../spec/support/timekeeping/fake_relay"

module TimekeepingRelaySpec
  # A relay endpoint over the monolith's in-memory projection endpoint
  # (TimekeepingContract::FakeRelay), so the gem is proved against the same
  # fake the projection consumer is built against.
  class FakeRelayEndpoint
    DELIVER_PATH = "/internal/v1/timekeeping/entry-snapshots"

    attr_reader :idempotency_keys

    def initialize(projection:, credential:)
      @projection = projection
      @credential = credential
      @idempotency_keys = []
    end

    def deliver(batch, idempotency_key:)
      @idempotency_keys << idempotency_key
      answer = @projection.call("POST", DELIVER_PATH,
                                headers: { "Authorization" => "Bearer #{@credential}", "Idempotency-Key" => idempotency_key },
                                body: batch)
      TimekeepingRelay::Response.new(status: answer.status, body: answer.body)
    end
  end
end
