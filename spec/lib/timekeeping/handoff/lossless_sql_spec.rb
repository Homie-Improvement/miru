# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::Handoff::LosslessSql, ".json_text" do
  it "writes a Time as UTC text with every microsecond kept" do
    time = Time.utc(2026, 1, 2, 3, 4, 5, 123_456)

    expect(described_class.json_text({ "t" => time })).to eq('{"t":"2026-01-02T03:04:05.123456000Z"}')
  end

  # A correction snapshot whose times lose their microseconds, or keep a local offset that a
  # timestamp column ignores, reaches the projection changed, and a later rollback is refused by
  # the projection check.
  it "writes a non-UTC TimeWithZone, top-level or nested, as the same instant in UTC" do
    utc = Time.utc(2026, 1, 2, 3, 4, 5, 123_456)
    zoned = utc.in_time_zone("Asia/Kolkata")

    text = described_class.json_text("created_at" => zoned, "nested" => { "updated_at" => zoned.to_datetime })

    expect(JSON.parse(text)).to eq(
      "created_at" => "2026-01-02T03:04:05.123456000Z",
      "nested" => { "updated_at" => "2026-01-02T03:04:05.123456000Z" }
    )
    expect(Time.iso8601(JSON.parse(text).fetch("created_at"))).to eq(utc)
  end

  it "writes a UTC DateTime and a +05:30 DateTime with the same text as the Time for that instant" do
    time = Time.utc(2026, 1, 2, 3, 4, 5, 123_456)
    offset_date_time = DateTime.new(2026, 1, 2, 8, 34, Rational(5_123_456, 1_000_000), "+05:30")

    text = described_class.json_text([time.to_datetime, offset_date_time])

    expect(text).to eq('["2026-01-02T03:04:05.123456000Z","2026-01-02T03:04:05.123456000Z"]')
  end

  it "still writes decimals, JSON null and nested values exactly as before beside a time" do
    value = {
      "rate" => BigDecimal("12.345678901234567890"),
      "missing" => Timekeeping::Handoff::Checkpoint::JSON_NULL,
      "nested" => { "list" => [1, "x", true] },
      "at" => Time.utc(2026, 1, 2, 3, 4, 5, 1)
    }

    expect(described_class.json_text(value)).to eq(
      '{"rate":12.34567890123456789,"missing":null,"nested":{"list":[1,"x",true]},' \
      '"at":"2026-01-02T03:04:05.000001000Z"}'
    )
  end
end
