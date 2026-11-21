---
module: spec/requests/api/v1/timesheet_entries
date: 2026-11-21
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - spec/support/timekeeping/owned_entries.rb
  - app/models/timesheet_entry.rb
tags:
  - timekeeping-ownership
  - arrange-owned-entries
  - billed-entries
  - factory-defaults
applies_when:
  - Replacing create(:timesheet_entry) with arrange_owned_entries rows
  - A spec needs a billed timesheet entry in any ownership state
---

# Spell out factory defaults when moving entry saves to arrange_owned_entries

## Context

The `:timesheet_entry` factory fills in values the old specs never wrote: a non-billable status, today's work date and a duration. `arrange_owned_entries` takes plain row hashes and has its own defaults, so these values are not carried over. The helper defaults `bill_status` to "unbilled". On a non-billable project, that status can fail the model's billable-project validation.

Billed rows have their own problem. `TimesheetEntry` refuses to create a row whose `bill_status` is "billed". The old specs created the row first and then called `update_column(:bill_status, ...)`.

## Solution

Write one base row that states the factory values the examples depend on:

```ruby
let(:entry_row) do
  { company:, user:, project:, work_date: Date.current, duration: 480, bill_status: "non_billable" }
end
```

For a billed entry, put `bill_status: "billed"` in the row. Do not flip the status after the arrange. `create_timesheet_entries` in `spec/support/timekeeping/owned_entries.rb` now creates a billed row as "non_billable" and then calls `update_column(:bill_status, "billed")`. Those are the same two steps the old specs used, so billed rows now pass through the helper in every state.

Keep `work_date: Date.current` on billed-refusal rows. Then a 403 comes from billing alone, not from the employee edit window.

## Why it matters

If you leave out a factory default, an example can still return the expected 403 or 422 for a different reason, so it stops proving what its name claims. Setting the billed status after the arrange is a second write. In the live timekeeping state it would also need a write to the Timekeeping app that no test helper provides.

## Evidence

- PR #528 adds an `entry_row` `let` with `work_date: Date.current`, `duration: 480` and `bill_status: "non_billable"` in `spec/requests/api/v1/timesheet_entries/bulk_actions/update_spec.rb` and `spec/requests/api/v1/timesheet_entries/bulk_actions/destroy_spec.rb`.
- The billed-refusal examples replace `update_column` calls with `entry_row.merge(bill_status: "billed")`.
- `spec/support/timekeeping/owned_entries.rb` changes `create_timesheet_entries` to create billed rows as non-billable and then call `update_column`. A comment there says the model refuses to create a billed row.
- `spec/integration/timekeeping/owned_entries_spec.rb` adds examples that arrange a billed row in the legacy, rollback and live timekeeping states. It also checks that non-billed rows keep their given status.
- The claim that the helper's "unbilled" default fails the billable-project validation comes from the plan for this change. The diff does not show it.
