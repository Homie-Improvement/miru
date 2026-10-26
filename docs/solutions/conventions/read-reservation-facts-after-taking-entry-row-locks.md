---
module: timekeeping
date: 2026-10-26
problem_type: convention
component: timekeeping_writers
severity: high
evidence_grounding: anchored
grounding_evidence: The comment in lock_entries in timekeeping/app/services/timekeeping/reservation_operations.rb and in locked_entries in entry_writer.rb states the stale-snapshot behaviour, and reservation_operations_race_spec.rb holds a writer at :rows_locked and checks the waiting writer sees the new reservation state.
audience: both
related_components:
  - reservation_operations
  - entry_writer
  - service_commands
tags:
  - postgresql
  - read-committed
  - row-locks
  - concurrency
  - reservations
applies_when:
  - A writer locks rows with FOR UPDATE and needs a fact derived from another table, such as whether an entry is reserved
  - Two writers can wait on the same entry rows and one of them changes reservations
---

# Read reservation facts in a second statement after taking entry row locks

## Context

Timekeeping writers lock `entries` rows `FOR UPDATE` in id order, then decide what to do from each entry's `reserved` flag. That flag comes from a subquery on `reservations` (`EntriesQuery::RESERVED`). Originally the lock and the flag were read in one statement.

Under PostgreSQL's default READ COMMITTED level, a statement that waits on a row lock re-checks the locked row once the lock is free. It does not re-run its subquery on other tables. So the waiting writer gets the `reserved` value from before it waited. If the writer that held the lock just added or removed a reservation, the waiter acts on the old value.

This caused three separate bugs in PR #63:
- A prepare waiting behind an abort saw `reserved: true`, so it skipped the version bump, audit row and outbox snapshot for the relock.
- An employee update waiting behind a prepare saw `reserved: false` and changed an entry that was now locked.
- A mark-billed waiting behind a successor invoice's commit still billed an entry its invoice no longer held.

## Solution

Split the read in two:

1. Lock the rows and take only their ids: `relation.order(:id).lock("FOR UPDATE").pluck(:id)`.
2. While the locks are held, read the derived facts in a new statement: `WriteSteps.reserved_rows(company_id, ids)`.

The second statement takes a fresh snapshot, so it sees what the previous lock holder committed. Mark-billed does the same: it locks its targets, then selects them again with `targets.where(id: ids)` so the reservation filter is evaluated after the wait.

Test each case with two connections. Hold the first writer at a named checkpoint, start the second, confirm with `pg_blocking_pids` that it is waiting, then release the first and check the final rows, versions, audit rows and snapshots.

## Why it matters

The one-statement form looks atomic, and it passes every single-connection test. It only fails when writers interleave. The result is silent: a locked entry is edited, a billed entry belongs to the wrong invoice, or downstream readers keep `locked: false` for an entry that is reserved. Any new writer that locks entries and reads a cross-table fact needs the two-step read.

## Evidence

- PR #63, head commit af7ba08d467267850f5c5fc9ac3091d3cf237d0a.
- `timekeeping/app/services/timekeeping/reservation_operations.rb`: `lock_entries` plucks ids under `FOR UPDATE`, then calls `WriteSteps.reserved_rows`; its comment explains the snapshot taken before the wait.
- `timekeeping/app/services/timekeeping/entry_writer.rb`: `locked_entries` changed from one `select("entries.*", EntriesQuery::RESERVED)...lock("FOR UPDATE OF entries")` statement to a pluck followed by `WriteSteps.reserved_rows`.
- `timekeeping/app/services/timekeeping/service_commands.rb`: `locked_targets` locks, then selects the targets again, with a comment on the mark-billed case.
- `timekeeping/spec/services/timekeeping/reservation_operations_race_spec.rb`: the examples "refuses an employee update that waited on a prepare of the same entry", "bills nothing for an invoice whose retained entry a successor committed while mark-billed waited" and "records the relock when a prepare for another invoice waits on an abort of the same entry".
