---
module: Timekeeping::LocalOwner
date: 2026-11-14
problem_type: design_pattern
component: timekeeping
severity: high
audience: both
related_components:
  - TimekeepingOwnership
  - Timekeeping::LocalOwner::ReservationOperations
tags:
  - postgresql
  - row-locks
  - nowait
  - lock-cycle
  - handoff
  - statement-timeout
applies_when:
  - A writer reads a shared row FOR SHARE NOWAIT so it can give up instead of waiting behind a queued UPDATE
  - A spec must prove that a database read returns without waiting on a lock
---

# FOR SHARE NOWAIT does not see a queued UPDATE; check tuple locks too

## Context

The local reservation writer reads the `timekeeping_ownership` row before it changes anything. Billing writes take that row FOR SHARE before they take the invoice lock. This writer takes the invoice lock first. A blocking read here could therefore close a lock cycle when a handoff has queued an UPDATE on the ownership row. To avoid waiting, the writer reads the row with `FOR SHARE NOWAIT` and answers 409 `stale_generation` if the row is busy.

NOWAIT alone does not detect the queued handoff. In PostgreSQL, a FOR SHARE request is compatible with the share locks other sessions already hold. It is granted at once, even while an UPDATE waits for those holders to finish. So NOWAIT raises `lock_not_available` only when an exclusive lock is actually held, not when an UPDATE is waiting in line.

## Solution

Run the NOWAIT read, then ask `pg_locks` whether another backend holds a tuple lock on the ownership table. A backend that waits to lock a row holds a lock on that tuple for as long as it waits. Any such tuple lock means a writer is queued:

```sql
SELECT EXISTS (
  SELECT 1 FROM pg_locks
  WHERE locktype = 'tuple' AND relation = to_regclass(?) AND pid <> pg_backend_pid()
)
```

In `WriteSteps.locked_generation_nowait`, the code raises `WriteSteps::OwnershipQueued` when this check is true, or when the NOWAIT read raises `ActiveRecord::LockWaitTimeout`. Each writer that calls it (`ReservationOperations` and `ServiceCommands`) rescues the error outside the attempt's `requires_new` savepoint. The attempt's rows roll back, the caller's transaction stays usable, and the answer is `stale_generation`. Only this read is turned into `stale_generation`; every other lock error still raises.

Trade-off: the check also fires on unrelated tuple locks on that table, for example another session that waits to lock the row FOR SHARE. That gives a false 409 that the caller retries. The other choice is to wait, which can close the lock cycle described above. A spurious, retryable 409 costs less, so this change takes it.

To prove in a spec that the read never waits, bound it with `SET LOCAL statement_timeout`, not `lock_timeout`. When `lock_timeout` expires it raises the same `lock_not_available` error that NOWAIT raises. The writer would then answer 409 from a read that did wait, and the spec would pass. When `statement_timeout` expires it cancels the query with a different error, so a read that waits fails the spec. Also assert with `blocked_by?` that the UPDATE is really queued behind the share holder before the call runs.

## Why it matters

An author who trusts NOWAIT ships a writer that still joins the lock cycle it was meant to avoid. A reviewer who sees `lock_timeout` in the spec could accept a test that cannot fail. The same applies to any other row that is read FOR SHARE by several writers and updated by a coordinator.

## Evidence

- PR #274, `app/services/timekeeping/local_owner/reservation_operations.rb`: `OWNERSHIP_LOCK = "FOR SHARE NOWAIT"`, `locked_generation`, and `ownership_update_queued?`. The comment on `ownership_update_queued?` states that PostgreSQL grants FOR SHARE beside other share holders while an update waits, so NOWAIT alone does not see a queued handoff.
- PR #274 body, under concerns about the written rules: the issue asked for NOWAIT only. The code adds the `pg_locks` check because PostgreSQL grants FOR SHARE NOWAIT while a handoff's update waits behind other share holders.
- PR #274, `spec/services/timekeeping/local_owner_reservations_spec.rb`, example "with an ownership update queued behind a FOR SHARE holder, a prepare answers 409 stale_generation without waiting". It checks `blocked_by?(updater_pids.first, holder_pids.first)`, runs the call under `SET LOCAL statement_timeout = '2s'`, and its comment explains why `lock_timeout` would let a blocking read pass.
- `app/services/timekeeping/local_owner/write_steps.rb`: `admitted_generation(lock:)` takes the lock clause, so entry routes keep plain `FOR SHARE`. PR #274 put the NOWAIT read in `ReservationOperations`; it has since moved to `WriteSteps.locked_generation_nowait`, which the reservation operations and the mark-billed and detach-entries commands (`LocalOwner::ServiceCommands`) share.
