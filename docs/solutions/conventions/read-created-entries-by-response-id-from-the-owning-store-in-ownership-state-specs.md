---
module: spec/requests
date: 2026-11-21
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - timekeeping
tags:
  - owned-entry
  - expect-owner-state
  - ownership-states
  - characterization-specs
applies_when:
  - A spec must pass in the legacy, timekeeping and rollback ownership states
  - An assertion reads or writes timesheet entries directly
---

# Read created entries by response id from the owning store in ownership-state specs

## Context

Timesheet entries can be owned by the legacy monolith, by the extracted Timekeeping app, or by the rollback store. A spec that must hold in all three states cannot use `TimesheetEntry.last`. That call reads only the legacy `timesheet_entries` table. In the other states the write lands somewhere else, so the read checks the wrong store, or picks up some other row.

## Solution

- Read the row the request created by the id the response returns, through the helper that reads the owning store:

```ruby
created_entry = owned_entry(json_response.dig("entry", "id"), state: TimekeepingOwnerState.current)
expect(created_entry.fetch("user_id")).to eq(user.id)
expect(created_entry.fetch("source")).to eq("cli")
```

- Arrange entry fixtures with `arrange_owned_entries([...])`, not `create(:timesheet_entry, ...)`. It returns ids, not records, so bind values such as `work_date` once and reuse that local in both the request and the assertion.
- Do all arranging first. Then call `expect_owner_state!` as the last statement before `send_request`, so no write sits between the state check and the operation it proves.
- Change only the assertions that read a store directly. Keep response assertions and expected values as they were.

## Why it matters

An assertion against the wrong store proves nothing about the behaviour under extraction. Reading by response id also ties the check to this request's row. Using `fetch` makes a missing key fail loudly instead of comparing `nil`.

## Evidence

- PR #494, `spec/requests/api/v1/cli/timesheet_entries/create_spec.rb`: the two `TimesheetEntry.last` assertions become a read through `owned_entry(json_response.dig("entry", "id"), state: TimekeepingOwnerState.current)`. `expect_owner_state!` is added right before `send_request`.
- PR #494, `spec/requests/api/v1/invoices/create_spec.rb`: `create(:timesheet_entry, ...)` becomes `arrange_owned_entries([...])`. `work_date` is bound once and reused. `expect_owner_state!` follows the arrange call and comes right before the request.
- The PR body reports both examples passing in the legacy, rollback and live timekeeping states.
