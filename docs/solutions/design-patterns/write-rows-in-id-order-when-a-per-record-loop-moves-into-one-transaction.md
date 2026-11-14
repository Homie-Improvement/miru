---
module: Timekeeping::Gateway
date: 2026-11-14
problem_type: design_pattern
component: service_layer
severity: high
audience: both
related_components:
  - Api::V1::TimesheetEntry::BulkActionController
  - TimesheetEntry
tags:
  - deadlock
  - row-locks
  - transaction
  - bulk-write
  - lock-order
applies_when:
  - A loop of per-record saves that used to commit row by row now runs inside one surrounding transaction
  - Callers choose the order of the records, for example from a list of ids in a request
---

# Write rows in id order when a per-record loop moves into one transaction

## Context

Before PR #251, the bulk move and bulk delete controller called the relation-wide `update(project_id:)` and `discard_all`. Each record saved and committed on its own, so each row lock lasted only for that one save.

The change moved both actions into `Timekeeping::Gateway`. There, one transaction (`perform`) covers the whole request, so that a generation change midway rolls back every earlier write. The per-record calls stayed the same, but every row the loop writes now stays locked until the transaction commits.

The lookup keeps request order. So one request naming `[a, b]` and another naming `[b, a]` each lock their first row, then wait on each other's. The code review ran exactly this race with two threads. Before the fix, one thread raised `ActiveRecord::Deadlocked`. After the fix, both finished.

## Solution

In the write loop, sort the records by a stable key (the primary key) before writing them. Keep the caller's order only for the answer:

```ruby
def write_each_admitted(entries, owner:, expected_generation:)
  entries.sort_by(&:id).each do |entry|
    raise OwnershipMoving unless EntryOwner.for(admitted_ownership(expected_generation)) == owner

    yield entry
  end
  entries.any?
end
```

`BulkResult#entries` is still built in request order, so the JSON the controller renders does not change.

## Why it matters

This change does not show up in a diff review. The loop body is the same calls as before, and only the transaction around them is new. Specs that send one request at a time pass either way. The deadlock appears only under concurrent load, as a failed request the user did nothing wrong to cause.

Whenever you add a transaction around writes the caller orders, check how long the locks now last, and give the writes one global order.

## Evidence

- PR #251, `app/services/timekeeping/gateway.rb`: `write_each_admitted` iterates `entries.sort_by(&:id)`. Its comment says "Each written row stays locked until the transaction ends, so entries are written in id order: two requests naming the same entries in opposite orders would otherwise wait on each other and deadlock."
- PR #251, `app/controllers/api/v1/timesheet_entry/bulk_action_controller.rb`: the removed lines show the earlier `updated_entries.update(project_id: target_project.id)` and `entries_to_discard.discard_all` calls, which ran with no surrounding gateway transaction.
- PR #251, `spec/services/timekeeping/gateway_spec.rb`: "writes legacy entries in id order whatever the request order, and answers them in request order" sends `[second.id, first.id]`. It asserts that the updates and discards ran in the order `[first.id, second.id]`, and that `moved.entries` keeps `[second.id, first.id]`.
- In the code review of PR #251, a two-thread script ran the opposite-order race against the gateway. Before the fix it returned `["ok", "ActiveRecord::Deadlocked"]`, and after the fix `["ok", "ok"]`.
