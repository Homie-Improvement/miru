---
module: timekeeping
date: 2026-10-26
problem_type: design_pattern
component: service_layer
severity: high
evidence_grounding: anchored
grounding_evidence: "PR #55: timekeeping/app/services/timekeeping/entry_command.rb adds SOURCES and BILL_STATUSES with a comment that a refused value would stop snapshot delivery; app/services/timekeeping/projection_consumer.rb#write runs refuse_foreign_projects!/refuse_foreign_agents! only on applying_items; spec/services/timekeeping/projection_consumer_spec.rb 'ignores an older snapshot whose project has since been deleted'"
audience: both
related_components:
  - timekeeping_service
  - projection_consumer
  - outbox_relay
tags:
  - outbox
  - projection
  - relay
  - poison-batch
  - validation
applies_when:
  - A relay advances past a batch only after the consumer answers 200
  - The consumer refuses a whole batch when any one snapshot is refused
  - The consumer validates more strictly than the producer, or checks references that can be deleted later
---

# A refused snapshot stalls the relay: stop bad values at the producer, and check references only on snapshots that will be written

## Context

The Timekeeping service writes entry snapshots to an outbox. A relay sends them in batches to `POST /internal/v1/timekeeping/entry-snapshots` in the monolith. The relay moves on only after a 200. `Timekeeping::ProjectionConsumer` applies a batch in one transaction, and any refused snapshot rolls back the whole batch with a 409 or 422.

Together, these rules make every refusal permanent. When the relay resends the same batch, it gets the same refusal, so every entry queued behind it stays undelivered. Reports read the `timesheet_entries` copy, so they stay stale until someone fixes the data by hand.

Two ways to cause this came up in review:

- **Producer looser than consumer.** Timekeeping's `EntryCommand` accepted any string for `source` and `bill_status`. `Timekeeping::SnapshotBatch` accepts only `TimesheetEntry::SOURCES` and the `bill_status` enum. One employee entry with `source: "fax"` was enough to block delivery for everyone.
- **Checks on snapshots the version guard will ignore.** The consumer first checked every snapshot's project. A delayed old version whose project was deleted since then got 422. The version guard would only have ignored that snapshot, so the 422 blocked the relay for no reason.

## Solution

1. **Make the producer refuse anything the consumer would refuse, at write time.** `Timekeeping::SnapshotValues` lists `SOURCES = %w[manual cli mcp automation import]`, `BILL_STATUSES = %w[non_billable unbilled billed]` and `REVIEW_STATUSES`, the values the monolith can store, with a rule for every snapshot field. `EntryCommand` answers 400 and the correction snapshot writer raises `Checkpoint::ShapeError` for any other value, so the bad value never reaches the outbox. When the consumer's allowed values change, change `entry_values` in `contracts/timekeeping/entry_snapshots.yml` and this list together; specs in both apps compare them.
2. **Check references only on snapshots that will be written.** `ProjectionConsumer#write` first works out `applying_items`. These are the snapshots newer than the stored row and newer than any earlier snapshot of the same entry in the batch. Only they go to `refuse_foreign_projects!` and `refuse_foreign_agents!`. An old snapshot that names a deleted project is counted as `ignored` and the batch answers 200.
3. **Keep the checks that protect data on every snapshot.** The generation check and the company-mismatch check still run on every snapshot in the batch. A refusal there means a writer that is no longer allowed, or a different tenant. Stopping delivery is right for those.

## Why it matters

With a 200-only relay, a refusal stops all later entries, not just the one bad snapshot. So decide on purpose which refusals are worth stopping delivery for. Tenant leaks and stale owners are. A value the producer should never have accepted is not: refuse it at the producer, with a 400 the user can see. A stale snapshot that would be ignored anyway is not either.

When you add a new consumer rule, ask two questions. Does the producer already enforce it? Can it fire on a snapshot the version guard will throw away?

## Evidence

- PR #55, head commit 7ea843ecace496b1f5da3c03227789401c3a2a1b.
- `timekeeping/app/services/timekeeping/entry_command.rb`: adds `SOURCES` and `BILL_STATUSES`. Its comment says the projection refuses any other value, so accepting one would stop snapshot delivery for every later entry. `timekeeping/spec/services/timekeeping/entry_command_spec.rb` checks that `"fax"` and `"paid"` are refused and that every allowed value is accepted.
- `app/services/timekeeping/snapshot_batch.rb`: `FIELD_CASTS` takes `source` only from `TimesheetEntry::SOURCES` and `bill_status` only from `TimesheetEntry.bill_statuses`. Any other value makes the whole batch invalid.
- `app/services/timekeeping/projection_consumer.rb`: the class comment says the relay resends any batch that did not get a 200. `write` calls `refuse_stale_generations!` and `refuse_company_mismatch!` on all items, but calls `refuse_foreign_projects!` and `refuse_foreign_agents!` only on `applying_items`. The comment there says a snapshot the version guard ignores may name a project deleted since, and must still be ignored.
- `spec/services/timekeeping/projection_consumer_spec.rb`, example "ignores an older snapshot whose project has since been deleted": the answer is 200 with `applied` 0 and `ignored` 1, and the stored row stays at version 2.
