# frozen_string_literal: true

require_relative "fake_timekeeping"

module TimekeepingContract
  # Wires Timekeeping::ReservationClient to a FakeTimekeeping, so specs run
  # the adapter the :timekeeping owner registers without any Net::HTTP call.
  module ReservationClientHelpers
    # A client over the fake whose service tokens are signed with the spec
    # key pair, as the fake in token mode checks them. Every call to
    # Timekeeping::ReservationClient.build, and so every adapter lookup for
    # the :timekeeping owner, returns it.
    def use_fake_timekeeping_reservations(fake, http: TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil))
      credential = lambda do |company_id:, operation:|
        Timekeeping::ServiceToken.mint(company_id:, operations: [operation], private_key: timekeeping_key_pair)
      end
      client = Timekeeping::ReservationClient.new(http:, credential:)
      allow(Timekeeping::ReservationClient).to receive(:build).and_return(client)
      client
    end

    # Forwards every request to http, so the fake applies it, then loses the
    # answer of each request the block accepts by raising the transport's
    # error, as a timed-out connection would.
    def timekeeping_answer_dropping_http(http, &drop_answer)
      dropping = Object.new
      dropping.define_singleton_method(:call) do |method, path, headers: {}, body: nil|
        response = http.call(method, path, headers:, body:)
        raise Timekeeping::ReservationClient::TransportError, "answer lost" if drop_answer.call(method, path)

        response
      end
      dropping
    end
  end
end

RSpec.configure do |config|
  config.include TimekeepingContract::ReservationClientHelpers
end
