---
module: Api::V1::TimesheetEntryController
date: 2026-11-21
problem_type: convention
component: api_controllers
severity: high
audience: both
related_components:
  - timekeeping_gateway
tags:
  - strong-parameters
  - tenant-boundary
  - mass-assignment
  - authorization
applies_when:
  - A controller resolves an association from a top-level param inside the current company
  - The same association key also appears in the permitted nested attributes
---

# Do not permit a foreign key in nested attributes that the controller resolves separately

## Context

`Api::V1::TimesheetEntryController` resolves the entry's project from the top-level `project_id`, inside the current company. Its `timesheet_entry_params` also permitted `:project_id` in the nested `timesheet_entry` hash. The legacy write sets `entry.project = project` and then runs `entry.update!(attributes)`. The nested `project_id` was assigned after the checked project and replaced it. A request with a valid top-level `project_id` and another company's project in `timesheet_entry[project_id]` answered 200 and moved the entry into the foreign project.

## Solution

Remove the key from the permit list, so the checked lookup is the only source of the association:

```ruby
params.require(:timesheet_entry).permit(:duration, :work_date, :note, :bill_status)
```

Add a request spec that sends both values and asserts that the entry keeps the company-scoped project.

## Why it matters

The company check on the top-level param looks like it guards the write, so a reviewer sees nothing wrong. The leak sits in a different method, the strong-params list. Assignment order decides which value wins. For this write, the attributes hash runs last. When a controller resolves an association by its own rule, check that the same key is not permitted anywhere else in the request.

## Evidence

- PR #534 removes `:project_id` from `timesheet_entry_params` in `app/controllers/api/v1/timesheet_entry_controller.rb`. It adds a comment saying a nested `project_id` would be assigned over `current_project` unchecked.
- `spec/requests/api/v1/timesheet_entries/gateway_spec.rb` adds the example "keeps the company-scoped project when the entry attributes name another company's project". It asserts `entry.reload.project_id` equals the company's project.
- A run recorded in the review of this pull request saw a 200 answer with the entry moved before the fix. After the fix, the new example passes.
