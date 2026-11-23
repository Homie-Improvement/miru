---
module: timekeeping tenant guard
date: 2026-11-23
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - timekeeping reservations
  - timekeeping projection consumer
tags:
  - tenant-isolation
  - positive-control
  - vacuous-pass
  - snapshot-batch
applies_when:
  - A cross-tenant probe can be refused by an earlier check than the one it targets
  - A positive control accepts any 2xx answer from a route that can succeed while changing nothing
---

# Make each tenant probe reach its target check and each owner control prove an effect

## Context

A tenant probe only proves something if the company check it targets is what refuses it. The owner's control only proves something if the owner's request really did the work. In the tenant guard, three setups passed even with the targeted check broken:

- **commit and abort invoice probes:** the requester's operation id was a fresh UUID that was never prepared. Commit and abort answered not_found for the missing operation before they compared invoices.
- **two-snapshot projection probe:** the batch puts the requester's newer own snapshot first in the array. But `Timekeeping::SnapshotBatch.parse` sorts items by `outbox_position`, which defaults to the entry version. So the foreign snapshot was processed first, and the case never exercised the path where one snapshot is applied and the next is refused.
- **owner controls for bulk move and bulk delete:** these routes answer 200 even when every entry result is `not_found`. A route that selects nothing passed both the foreign probe and the control.

## Solution

- Before the commit and abort invoice probes, the requester prepares its own invoice under the probe's operation id (`REQUESTER_OPEN_OPERATION` in `PRECONDITIONS`). After that, only the invoice check can turn the probe away. The spec aborts that operation afterwards.
- Give the snapshots explicit positions (`LEADING_SNAPSHOT_POSITION = 1`, `SNAPSHOT_POSITION = 2`). A meta example runs the batch through the consumer's own parser and asserts the order `[501, 1501]`. Do not trust array order when the consumer sorts the items.
- After each probe that runs before its control, require the owner's bulk result to name its entry as `moved` or `deleted`. Also require the stored row's version to go up by one and its discarded flag to match the route (`tenant_guard_entry_write_effects`).

To check this kind of change, break the targeted code on purpose, confirm that the guard fails, then restore the code.

## Why it matters

Each of these setups left the guard green while the isolation it claims to test was broken. A guard that cannot fail is worse than no guard, because reviewers trust it.

## Evidence

- In PR #593, `spec/support/timekeeping/tenant_guard_cases.rb` adds `PRECONDITIONS` for `%i[reservations commit invoice_id]` and `%i[reservations abort invoice_id]`, the two snapshot position constants, and `with_newer_own_snapshot`.
- `spec/meta/timekeeping_tenant_guard_surfaces_spec.rb` adds the example that parses the probe with `Timekeeping::SnapshotBatch.parse` and expects `[501, 1501]`.
- `tenant_guard_owner_control_after` and `tenant_guard_entry_write_effects` in `spec/integration/timekeeping/tenant_guard_spec.rb` check the bulk result and the stored version and discarded state.
- The review answers in PR #593 report these results. With the commit invoice check removed, the commit invoice probe failed because a digest changed. With `applied = []` set in `EntryWriter#bulk_change`, the example failed at the owner control's bulk result. With the leading snapshot at position 3, the ordering example failed.
