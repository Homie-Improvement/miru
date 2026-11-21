---
module: spec/support/timekeeping
date: 2026-11-21
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - timekeeping
  - request_specs
tags:
  - timekeeping-ownership
  - negative-assertion
  - owned-entries
  - projection
  - regression-specs
applies_when:
  - A spec asserts that no timesheet entry was stored, and it must pass in the legacy, timekeeping and rollback owner states
  - An assertion uses TimesheetEntry.where(...) to be_empty, or a similar projection query, to prove absence
---

# Check for a missing entry by listing the owning store, not the projection

## Context

Timesheet entries can live in one of three stores, chosen by the owner state: `legacy` (the `timesheet_entries` table), `rollback` (`Timekeeping::LocalEntry`), or `timekeeping` (the live Timekeeping app). The `timesheet_entries` table is only a projection outside the legacy state. It is a copy, not the store that owns the data.

A "nothing was stored" assertion such as `expect(TimesheetEntry.where(project: other_project, user:)).to be_empty` reads that projection. Outside legacy, the store that owns entries does not write the projection on create. So the check passes whatever the owner holds. It turns into a test that cannot fail, and nothing warns you.

The usual fix for positive read-backs is to read the id from the response with `owned_entry`. That does not work here. A refused request returns no id, so there is nothing to read.

## Solution

Use `owned_entries(state:)` from `spec/support/timekeeping/owned_entries.rb`. It returns every entry the owning store holds, in id order, as hashes with the same string keys as `owned_entry`. Filter that list by the fields the old query used, and assert the result is empty:

```ruby
owned_for_other_project = owned_entries(state: TimekeepingOwnerState.current).select do |entry|
  entry.fetch("project_id") == other_project.id && entry.fetch("user_id") == user.id
end
expect(owned_for_other_project).to be_empty
```

The reader picks a lister from a table keyed by state (`OWNED_ENTRY_LISTERS`), next to the existing `OWNED_ENTRY_READERS`. It first calls `TimekeepingOwnerState.fetch(state)`, so a misspelled state raises `ArgumentError` and the check never silently reads the wrong store. In the timekeeping state it reads the live app's checkpoint export, so tag the example `committed_data: true`. The live app reads company, user and project rows over its own connection.

Do not delete the absence check to make the spec pass in every state. That weakens what the example proves. Do not keep the projection query either, because it cannot fail in two of the three states.

## Why it matters

A negative assertion that cannot fail is worse than no assertion. It reads as proof that a refused request stored nothing, but it proves nothing in the timekeeping and rollback states. If the controller ever stored an out-of-scope entry in the owning store, the projection query would still pass. The listing reader makes the check fail in every state when the owner holds a matching entry.

## Evidence

- PR #523 changes `spec/requests/api/v1/agent/timesheet_entries/create_spec.rb`. In the example "rejects a project outside the backing user's membership scope", it replaces `TimesheetEntry.where(project: other_project, user:)` with the `owned_entries` filter shown above, and adds `committed_data: true`.
- PR #523 adds `owned_entries` and `OWNED_ENTRY_LISTERS` to `spec/support/timekeeping/owned_entries.rb`. The listers read `TimesheetEntry.unscoped` in legacy, `Timekeeping::LocalEntry.with_reserved` in rollback, and the `entries` rows of `live_owned_entry_store.export_checkpoint` in timekeeping.
- PR #523 adds examples to `spec/integration/timekeeping/owned_entries_spec.rb`. They show that in rollback the reader returns the `LocalEntry` note, not a changed projection note. They show it returns an empty list in rollback when only a projection row exists. They show it raises `ArgumentError` for the state `"Legacy"`. They show the live timekeeping state lists only entries loaded into the app.
- The claim that the owning store does not write the projection on create outside legacy comes from the PR #523 plan, which points to `Timekeeping::Gateway#create` in `app/services/timekeeping/gateway.rb`. That file is not part of this change. To check it, read that method and confirm it returns an unsaved entry outside legacy.
