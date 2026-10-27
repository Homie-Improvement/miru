---
module: spec/services/invoices
date: 2026-10-27
problem_type: convention
component: testing_framework
severity: low
evidence_grounding: anchored
grounding_evidence: "`hold_writer` in spec/services/invoices/prepared_reservations_concurrency_spec.rb wraps the adapter call in `ApplicationRecord.transaction`, pushes to `reached`, pops `release`, and raises `ActiveRecord::Rollback` when `roll_back:` is set; every example then asserts `blocked_by?` is true while the holder is paused, and PR #230 changes no production code."
audience: author
related_components:
  - database
  - service_layer
tags:
  - committed-data
  - concurrency
  - savepoint
  - row-locks
  - rspec
applies_when:
  - A race spec needs the first writer to keep its locks while a second writer starts
  - "The service under test opens its own transaction with requires_new: true"
---

# Hold a race writer in an outer transaction paused on a queue

## Context

A two-connection race spec needs the first writer to stop while it still holds its locks. Only then can the second writer start, block, and be checked with `blocked_by?`.

`Invoices::PreparedReservations` runs its work in its own `requires_new: true` transaction. A tempting approach is to add a checkpoint or callback inside the service, so the test can pause it mid-call. That puts test-only code in production.

## Solution

Run the service call inside an outer transaction on the writer's own connection, and pause that outer transaction on a queue after the call returns:

```ruby
def hold_writer(roll_back: false)
  committed_data_thread(holder_pids) do
    held = nil
    ApplicationRecord.transaction do
      held = yield
      reached << true
      release.pop
      raise ActiveRecord::Rollback if roll_back
    end
    held
  end
end
```

Inside the outer transaction, the service's `requires_new: true` block becomes a savepoint. Releasing a savepoint does not release the row locks taken inside it. They stay held until the outer transaction commits or rolls back. So the writer finishes its whole call, then sits on `release.pop` with every lock still held.

The test waits on `reached`, starts the second writer, checks `blocked_by?`, and only then pushes to `release`. Setting `roll_back: true` gives the "first writer rolled back" schedule with the same helper.

## Why it matters

This holds the race open with no change to the code under test. The spec then tests the real lock order, not a version altered for testing. It also lets the test assert the first writer's return value, because the call has fully returned before the pause.

One limit: this pauses the writer after its call, not partway through it. A race that needs the writer stopped between two statements of the service still needs another approach.

## Evidence

- PR #230 adds `hold_writer` to `spec/services/invoices/prepared_reservations_concurrency_spec.rb`. The file's header comment states that the first writer runs inside an outer transaction paused on a queue, so the adapter's savepoint keeps every lock it took until the example releases it.
- Each of the six examples in that file asserts `blocked_by?` is true while the holder is paused on `release`.
- The last example passes `roll_back: true` and asserts the first invoice has no operation rows afterwards, which shows the outer rollback undid the adapter's committed savepoint.
- The pull request changes only that spec file; no production code changes.
