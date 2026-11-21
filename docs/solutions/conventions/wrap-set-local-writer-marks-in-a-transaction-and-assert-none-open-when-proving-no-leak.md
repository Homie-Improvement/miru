---
module: timekeeping
date: 2026-11-21
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - timekeeping
  - database
tags:
  - set-local
  - miru-writer
  - writer-mark
  - connection-pool
  - projection-consumer
applies_when:
  - Code or specs call Timekeeping::LegacyWriterMark.call
  - A spec proves a session-variable mark does not carry over to the next write on a pooled connection
---

# Wrap SET LOCAL writer marks in a transaction, and assert none is open when proving no leak

## Context

The session variable `miru.writer` records which writer changed a `timesheet_entries` row. Both `Timekeeping::LegacyWriterMark` and `Timekeeping::ProjectionConsumer` set it with `SET LOCAL`. `SET LOCAL` keeps a value only until the current transaction ends. `LegacyWriterMark.call` does not open a transaction itself.

## Solution

When you write with the legacy mark, open the transaction yourself:

```ruby
connection.transaction do
  Timekeeping::LegacyWriterMark.call(connection) { guard_touch(connection, entry_id) }
end
```

When you prove that the consumer's mark ends with its commit, take one pooled lease. First assert that no transaction is open. Then run the consumer and an unmarked write on that same connection:

```ruby
ActiveRecord::Base.connection_pool.with_connection do |connection|
  expect(connection.open_transactions).to eq(0)
  Timekeeping::ProjectionConsumer.call(batch:, idempotency_key: ...)
  guard_touch(connection, entry_id)
end
```

Next, check that both logged rows have the same `backend_pid`. Then check that the UPDATE's writer is not `projection`.

## Why it matters

Without the outer transaction, the legacy write is logged with no mark. A test that expects `legacy_gateway` then fails, or one that expects an unmarked write passes for the wrong reason. If an outer transaction is open around the consumer, the consumer's `SET LOCAL` belongs to that outer transaction. The mark then really does reach the next write, so a leak test cannot tell a leak from expected behaviour. The `open_transactions` check stops a transactional test setup from turning the test into a no-op. The matching `backend_pid` check proves both writes came from the same database session.

## Evidence

- In PR #568, `guard_marked_write` in `spec/integration/timekeeping/single_writer_guard_spec.rb` wraps `Timekeeping::LegacyWriterMark.call` in `connection.transaction`. Its comment says the mark is SET LOCAL and opens no transaction of its own.
- `guard_expect_pooled_write_unmarked` in the same file runs `expect(connection.open_transactions).to eq(0)` before it calls `Timekeeping::ProjectionConsumer.call`. Its comment says the consumer's mark ends when the consumer commits only if no transaction is open around it. The method then checks that the UPDATE row's writer is not `projection` and that it has the same `backend_pid` as the consumer's INSERT row.
