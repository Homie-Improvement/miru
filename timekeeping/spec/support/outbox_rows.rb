# frozen_string_literal: true

# One place that knows the outbox_snapshots columns, so a schema change edits
# this builder rather than a row literal in every spec.
#
# Rows go in through insert_all!, which writes the "id" key straight to the
# entry-id column; OutboxSnapshot#id= is never involved. outbox_position is the
# primary key: the sequence assigns it unless a row overrides it.
module OutboxRows
  # A row with every NOT NULL column that has no database default, plus
  # enqueued_at and sent_at. Every row names the same columns, because
  # insert_all! needs that of the rows in one call. sent_at defaults to nil so
  # a row is unsent unless the spec says otherwise; specs that compare
  # companies or versions pass company_id and version themselves.
  def outbox_row(**overrides)
    now = Time.current
    {
      id: 1, project_id: 1, user_id: 1, work_date: Date.new(2026, 3, 2), duration: 60.0,
      bill_status: "unbilled", review_status: "not_required", locked: false, source: "manual",
      source_metadata: {}, proof_metadata: {}, created_at: now, updated_at: now,
      company_id: 1, version: 1, generation: 1, enqueued_at: now, sent_at: nil
    }.merge(overrides)
  end

  # Inserts the rows and returns their outbox positions in the order given.
  def insert_outbox_rows(*rows)
    OutboxSnapshot.insert_all!(rows, returning: %w[outbox_position]).rows.flatten
  end
end

RSpec.configure do |config|
  config.include OutboxRows
end
