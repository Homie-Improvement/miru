---
module: timekeeping
date: 2026-11-21
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - projection_consumer
  - relay_job
  - harvest_importer
tags:
  - rollback
  - prepared-store
  - outbox
  - relay
  - generation
applies_when:
  - A spec reads timesheet_entries while the prepared store owns entries (rollback owner state)
  - A spec stub raises the ownership generation or makes an import fail partway through
---

# In prepared-store specs, relay before every projection read and before any generation bump

## Context

In the rollback owner state, `Timekeeping::EntryOwner` answers `:prepared`. In that state `Timekeeping::Gateway#import` writes only to the prepared store and its outbox. Rows reach `timesheet_entries` only when `Timekeeping::RelayJob` delivers the outbox to `Timekeeping::ProjectionConsumer`. The consumer refuses snapshots from an earlier ownership generation.

The obvious fix is to relay once, after a successful `process`. That leaves two kinds of example failing:

- Examples whose stub raises the generation after the first row is written. By the time anything relays, the consumer refuses that row's snapshot.
- Examples whose import ends in an expected error with the generation unchanged, such as `OwnershipMoving` or `IOError`. `process` raises, so an after-import delivery never runs, but the example then checks the row it kept.

## Solution

Use `relay_local_entries_to_projection(company)` from `spec/support/timekeeping/projection_relay.rb`. It runs the real relay and consumer only when the prepared store owns entries. In any other state it does nothing. Call it before each point where the example next reads the projection:

1. After a successful import. The importer spec wraps this as `run_harvest_import`.
2. Inside a stub that raises the generation or starts a handoff: after `original.call` and before the change.

```ruby
if calls == 1
  # Delivered before the change: the projection refuses an earlier generation's snapshot after it.
  relay_local_entries_to_projection(fold_gen_company)
  TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).increment!(:generation)
end
```

3. Right after an expected error, before checking the kept rows and before any rerun.

```ruby
expect { described_class.new(import).process }.to raise_error(Timekeeping::Gateway::OwnershipMoving)
relay_local_entries_to_projection(rerun_dup_company)
expect(rerun_dup_entries("same work")).to eq(1)
```

Do not copy rows into `timesheet_entries` by hand. Copied rows would hide a snapshot that is missing from the outbox. The helper raises `TimekeepingProjectionRelay::Undelivered` with the consumer's answer when any row for that company stays unsent. A delivery made after a generation bump therefore fails loudly instead of showing up as a missing row; a delivery made before the rows are written still passes silently, so place each call after the write it must deliver.

## Why it matters

If delivery happens at the wrong point, the example fails for a reason the spec created, not the code. The tempting fixes then weaken coverage: skipping the example, tagging it legacy-only, or moving the assertion to another store. Following the three delivery points keeps both the expected refusal and the kept-row checks real in rollback.

## Evidence

- PR #491 adds `spec/support/timekeeping/projection_relay.rb`. The helper returns early unless `Timekeeping::EntryOwner.for(TimekeepingOwnership.current) == :prepared`, runs `Timekeeping::RelayJob.perform_now`, and raises `Undelivered` for rows of that company that stay unsent.
- `spec/contracts/timekeeping/projection_relay_spec.rb` has the example "relay helper raises when the generation moved after the write instead of leaving the row silently missing". It increments the generation after a prepared write and expects `Undelivered`, with the row not projected and still unsent.
- `spec/services/imports/harvest_time_entries_importer_spec.rb` in PR #491 calls the helper inside the generation-change and handoff stubs before the change. It also calls the helper right after the `OwnershipMoving` and `IOError` expectations, and uses `run_harvest_import` after successful imports.
