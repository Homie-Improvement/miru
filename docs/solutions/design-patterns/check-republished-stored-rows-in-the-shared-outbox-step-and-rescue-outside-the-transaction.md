---
module: timekeeping
date: 2026-10-26
problem_type: design_pattern
component: service_layer
severity: medium
evidence_grounding: anchored
grounding_evidence: timekeeping/app/services/timekeeping/write_steps.rb write_outbox builds the snapshots, calls SnapshotValues.invalid_snapshots and raises UnpublishableRows before pg_advisory_xact_lock and insert_all!; entry_writer.rb, service_commands.rb and reservation_operations.rb rescue it after their transaction; service_commands_spec.rb shows no receipt is kept and a retry with the same operation id succeeds once the value is fixed
audience: both
related_components:
  - outbox
  - idempotency_receipts
  - snapshot_values
tags:
  - outbox
  - stored-values
  - snapshot-rules
  - transaction-rollback
  - idempotency
applies_when:
  - A writer copies stored entry rows into outbox_snapshots without resending every field
  - Adding a new caller of WriteSteps.write_outbox
  - A typed refusal is raised inside a transaction that also stores an idempotency receipt
---

# Check republished stored rows in the shared outbox step, and rescue the refusal outside the transaction

## Context

The monolith's projection refuses a whole batch when one snapshot is bad. The relay delivers in outbox order, so one bad snapshot stops delivery for every company.

Request checks only cover the fields a request sends. Many writes resend nothing and copy the stored row as it is: mark-billed, detach-entries, an update without `source`, destroy, bulk move and delete, and reservation changes that flip `locked`. A stored value can be bad without ever passing a check. For example, a checkpoint load copies values in without checking them, and the `entries` table has no CHECK constraints.

## Solution

Put the check in the one step every normal writer uses to publish, `Timekeeping::WriteSteps.write_outbox`:

```ruby
snapshots = rows.map { |row| OutboxFields.row(row, generation:) }
invalid = SnapshotValues.invalid_snapshots(snapshots)
raise UnpublishableRows, invalid if invalid.any?

connection.execute(... pg_advisory_xact_lock ...)
OutboxSnapshot.insert_all!(snapshots)
```

Four details carry the design:

- **Check the hashes you insert, not the model.** The same `snapshots` array is checked and then inserted. Some fields are computed when the row is built; `locked` comes from the reservation state, not the column.
- **Refuse the whole batch before the lock.** One bad row raises before any insert. Never insert the valid rows and skip the bad one, because that leaves the outbox out of step with storage.
- **Rescue outside the transaction.** `EntryWriter#call`, `ServiceCommands#call` and `ReservationOperations#call` each rescue `WriteSteps::UnpublishableRows` after the transaction block and answer `error.outcome`. The raise happens inside the transaction, so the entry change, audit rows, reservation rows and idempotency receipt all roll back. A retry with the same key then runs as a first attempt against what is stored then.
- **Name fields, never values.** The 409 body is `{"reason":"unpublishable_entry","entries":[{"entry_id":..,"fields":[..]}]}`, and the error message lists only ids and field names. A bad stored value can hold anything, including a secret, so it must not reach a response or a log line.

A write that repairs the bad field passes, because the check runs on the row as it will commit. That update is the repair route for an unlocked entry.

## Why it matters

If you check only at the request, every write that copies stored data can bypass the check. A check in each writer would be repeated three times and would drift. Rescuing inside the transaction, or after a receipt commits, would store the refusal as the answer for that key. The retry would then replay it forever, even after the value is fixed.

A new code path that inserts outbox rows outside `write_outbox` gets none of this protection. `Handoff::CorrectionSnapshots` is the one deliberate exception, and it keeps its own check.

## Evidence

- PR #181, `timekeeping/app/services/timekeeping/write_steps.rb`: `write_outbox` raises `UnpublishableRows` before the advisory lock and `insert_all!`. `UnpublishableRows#outcome` builds the 409 body from ids and field names.
- `timekeeping/app/services/timekeeping/snapshot_values.rb`: the new `invalid_snapshots` maps each failing entry id to its `invalid_fields`.
- `timekeeping/app/services/timekeeping/entry_writer.rb`, `service_commands.rb`, `reservation_operations.rb`: each `call` adds `rescue WriteSteps::UnpublishableRows => error` after the transaction and returns `error.outcome`.
- `timekeeping/spec/services/timekeeping/write_steps_spec.rb`: a batch with the bad row last inserts nothing. The body and the error message never include the stored value.
- `timekeeping/spec/services/timekeeping/service_commands_spec.rb`: a refused detach keeps no `ServiceIdempotencyReceipt` for its operation id, and the same id succeeds after the value is fixed.
- `timekeeping/spec/services/timekeeping/entry_writer_spec.rb`: an update that sets `source` to `"manual"` over a stored `"legacy"` publishes.
