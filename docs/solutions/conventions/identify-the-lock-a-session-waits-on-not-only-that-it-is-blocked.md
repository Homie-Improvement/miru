---
module: spec/integration/timekeeping
date: 2026-11-24
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - spec/support/committed_data.rb
  - spec/support/timekeeping/section_9_3_live.rb
tags:
  - concurrency
  - blocked-by
  - pg-locks
  - advisory-lock
  - lock-discrimination
applies_when:
  - A spec must fail when one specific lock is removed
  - The code under test takes more than one lock, or writes rows before it takes the lock under test
  - Several sessions wait on one held row
---

# Identify the lock a session waits on, not only that it is blocked

## Context

Concurrency specs in this repository prove a wait with `blocked_by?` from `spec/support/committed_data.rb`. That helper asks PostgreSQL's `pg_blocking_pids` whether one backend waits on another. It answers true for any lock between them: an advisory lock, a row lock, or the row lock a foreign-key check takes.

So a spec that wants to prove "this lock serializes these callers" can stay green after that lock is removed. Some other lock still makes the second caller wait. The spec has stopped testing what its name says.

PR #596 hit this in two places:

- **Two saves of one invoice.** Each save writes its rows during `before_save`. It takes the invoice-identity advisory lock only later, when the reservation boundary flushes. If both saves update the same line or the invoice row, the second save waits on that row lock. It never reaches the advisory lock.
- **Two prepares of one entry.** The test holds the entry row `FOR UPDATE`. A reservation INSERT also waits on that held row, because its foreign key to `entries` locks the referenced row. A blocking chain of INSERTs can look like the entry lock working.

## Solution

Prove the wait, then prove which lock it is.

1. **Design the callers so they share only the lock under test.** In the two-saves example, the draft has two separate lines. Each save points a different line at a new entry with the same rate and quantity. Totals do not change, so neither save writes the `invoices` row or the other's line.
2. **For an advisory lock, look for the ungranted row in `pg_locks`.** A bigint advisory key is listed with its high 32 bits in `classid`, its low 32 bits in `objid`, and `objsubid = 1`. Rebuild the key the way the product builds it and compare:

   ```sql
   SELECT EXISTS (
     SELECT 1 FROM pg_locks
     WHERE pid = $1 AND locktype = 'advisory' AND objsubid = 1 AND granted = $2
       AND ((classid::bigint << 32) | objid::bigint) = hashtextextended($3, 0)
   )
   ```

   Pass the key from the product's own method (`Invoices::OperationLock.key`), not a copy of how it is built.
3. **For a row lock, check the waiting statement's text.** Read `query` from `pg_stat_activity` for each waiter. Accept the wait only when the statement is the locking SELECT, here `/\ASELECT "entries"\."id" FROM "entries" .* FOR UPDATE\b/m`. This rejects an INSERT that waits on its foreign-key check.
4. **Find queued waiters through the whole chain.** When two sessions wait for one held row, only the first is blocked by the holder. The second is blocked by the first waiter. A recursive query over `pg_blocking_pids` finds both. Then require at least one waiter that the holder blocks directly.

## Why it matters

A lock-discrimination spec is only worth having if removing the lock turns it red on an assertion. If an unrelated row lock or foreign-key wait keeps `blocked_by?` true, the spec fails later in an unrelated way, or not at all. A reviewer reading "the second save waits" cannot tell this apart from a real proof. Check the shared rows and the waiting statement whenever a spec claims a specific lock.

## Evidence

- PR #596, `spec/support/timekeeping/section_9_3_live.rb`: adds `OPERATION_LOCK_SQL`, which decodes the advisory key from `classid`, `objid` and `objsubid = 1`. It also adds `section_9_3_operation_lock?`, whose comment says `blocked_by?` alone cannot tell this wait from a wait on a row lock.
- The same file adds `TIMEKEEPING_WAITERS_SQL`, a recursive query whose comment says the second waiter waits on the first waiter, not on the holder. It adds `ENTRY_LOCK_QUERY` and `section_9_3_timekeeping_waiting_on_entry_lock?` to reject waits from a later statement such as the reservation INSERT.
- `spec/integration/timekeeping/section_9_3_spec.rb` in PR #596: the two-saves example repoints two different existing lines, keeping rate and quantity. It asserts both `blocked_by?(second_pid, first_pid)` and `section_9_3_operation_lock?(..., granted: false)`. The two-prepares example asserts `entry_lock_waiters` equals `waiters`, with a comment about the foreign-key wait.
- The author ran the `ENTRY_LOCK_QUERY` pattern against both statements. It matched the entry-locking SELECT and did not match the reservation INSERT. The PR body records that with both save-path `OperationLock.acquire!` calls removed, the saves example failed `blocked_by?` and the lock check.
