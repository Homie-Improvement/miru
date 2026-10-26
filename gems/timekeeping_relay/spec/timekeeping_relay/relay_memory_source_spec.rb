# frozen_string_literal: true

RSpec.describe TimekeepingRelay::Relay, "against an in-memory outbox source" do
  def recording_endpoint(answer)
    posts = []
    endpoint = Object.new
    endpoint.define_singleton_method(:posts) { posts }
    endpoint.define_singleton_method(:deliver) do |batch, idempotency_key:|
      posts << [batch, idempotency_key]
      answer.call(batch)
    end
    endpoint
  end

  [
    [401, { "reason" => "unauthorized" }],
    [403, { "reason" => "forbidden" }],
    [404, { "reason" => "not_found" }],
    [500, "<html>Internal error</html>"],
    [302, nil],
    [nil, nil]
  ].each do |status, body|
    it "marks nothing and sends no second batch when the endpoint answers #{status.inspect}" do
      source = TimekeepingRelaySpec::MemoryOutboxSource.new((1..4).map { |position| TimekeepingRelaySpec::MemoryOutboxSource.row(position) })
      endpoint = recording_endpoint(->(_batch) { TimekeepingRelay::Response.new(status:, body:) })

      result = described_class.new(source:, endpoint:).deliver(limit: 2)

      expect(result).to eq(sent: 0, last_position: nil)
      expect(source.mark_calls).to be_empty
      expect(endpoint.posts.size).to eq(1)
    end
  end

  it "sends five rows as three ordered batches when the limit is two" do
    source = TimekeepingRelaySpec::MemoryOutboxSource.new([5, 1, 4, 2, 3].map { |position| TimekeepingRelaySpec::MemoryOutboxSource.row(position) })
    endpoint = recording_endpoint(lambda do |batch|
      TimekeepingRelay::Response.new(status: 200, body: { "applied" => batch["snapshots"].size, "ignored" => 0 })
    end)

    result = described_class.new(source:, endpoint:).deliver(limit: 2)

    batches = endpoint.posts.map { |batch, _key| batch["snapshots"].map { |item| item["outbox_position"] } }
    expect(batches).to eq([[1, 2], [3, 4], [5]])
    expect(source.mark_calls).to eq([[1, 2], [3, 4], [5]])
    expect(result).to eq(sent: 5, last_position: 5)
    expect(result.keys).to eq(%i[sent last_position])
  end

  it "counts a 200 that reports every row ignored as delivered" do
    source = TimekeepingRelaySpec::MemoryOutboxSource.new([TimekeepingRelaySpec::MemoryOutboxSource.row(8)])
    endpoint = recording_endpoint(->(_batch) { TimekeepingRelay::Response.new(status: 200, body: { "applied" => 0, "ignored" => 1 }) })

    expect(described_class.new(source:, endpoint:).deliver(limit: 10)).to eq(sent: 1, last_position: 8)
    expect(source.mark_calls).to eq([[8]])
  end

  it "posts nothing for an empty outbox" do
    source = TimekeepingRelaySpec::MemoryOutboxSource.new([])
    endpoint = recording_endpoint(->(_batch) { raise "must not be called" })

    expect(described_class.new(source:, endpoint:).deliver(limit: 10)).to eq(sent: 0, last_position: nil)
    expect(endpoint.posts).to be_empty
  end
end
