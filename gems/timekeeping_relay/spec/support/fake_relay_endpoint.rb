# frozen_string_literal: true

require_relative "../../../../spec/support/timekeeping/fake_relay"

module TimekeepingRelaySpec
  # A relay endpoint over the monolith's in-memory projection endpoint
  # (TimekeepingContract::FakeRelay), so the gem is proved against the same
  # fake the projection consumer is built against.
  #
  # Scripted answers are used first, one per post, without reaching the
  # projection; they stand in for answers the consumer never gives, such as an
  # outage. Once they run out, every post goes to the projection on the
  # production deliver path. With no projection left to answer, deliver raises,
  # so a missing script fails the example instead of passing it.
  class FakeRelayEndpoint
    attr_reader :posts

    # An endpoint over a fresh projection, with a service credential that holds
    # the given operations. Returns the endpoint and the projection, so every
    # spec builds the consumer fake the same way.
    def self.over_projection(name: "timekeeping", operations: ["deliver"], answers: [])
      timekeeping = TimekeepingContract::FakeTimekeeping.new
      credential = timekeeping.add_service(company_id: nil, name:, operations:)
      projection = TimekeepingContract::FakeRelay.new(source: timekeeping)
      [new(projection:, credential:, answers:), projection]
    end

    def initialize(projection: nil, credential: nil, answers: [])
      @projection = projection
      @credential = credential
      @answers = answers.dup
      @posts = []
    end

    def deliver(batch, idempotency_key:)
      post = { batch:, key: idempotency_key }
      @posts << post
      post[:answer] = @answers.empty? ? project(batch, idempotency_key) : @answers.shift
    end

    def idempotency_keys
      @posts.map { |post| post[:key] }
    end

    private

      def project(batch, idempotency_key)
        raise ArgumentError, "no scripted answer left and no projection to post to" unless @projection

        answer = @projection.call("POST", TimekeepingRelay::HttpEndpoint::DELIVER_PATH,
                                  headers: { "Authorization" => "Bearer #{@credential}", "Idempotency-Key" => idempotency_key },
                                  body: batch)
        TimekeepingRelay::Response.new(status: answer.status, body: answer.body)
      end
  end
end
