---
module: spec/requests/api/v1/time_tracking
date: 2026-11-14
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - timekeeping
  - timesheet_entries
tags:
  - fake-service
  - id-collision
  - postgres-sequence
  - request-specs
  - timekeeping
applies_when:
  - A spec creates a record in a fake remote service and a local row of the same kind
  - An assertion proves the response came from the remote owner by comparing ids
---

# Take a fake remote record's id from the local table's sequence when a spec compares ids

## Context

The owner-reads request spec checks that a time-tracking read returns the entry held by the Timekeeping service, not a local `timesheet_entries` row. It proves this partly by id: `expect(owner_entry_id).not_to eq(projected.id)`.

The fake Timekeeping numbers its entries from 1001. Local `timesheet_entries` ids can reach 1001 too. Once they did, the local factory entry and the fake entry both got id 1001. The check failed with "Expected 1001 not to eq 1001" in 3 of 3 runs on the base branch. A starting value like 1001 only puts the collision off until enough local rows exist.

## Solution

Allocate the fake record's id from the local table's own Postgres sequence, then pass it to the fake explicitly:

```ruby
id = ActiveRecord::Base.connection.select_value("SELECT nextval(pg_get_serial_sequence('timesheet_entries', 'id'))")
fake_timekeeping.add_entry(company_id: company.id, user_id: user.id, project_id: project.id,
                           work_date:, duration: 45.0, note:, id:, **attributes).fetch("id")
```

`nextval` uses up the value, so no later `timesheet_entries` row can ever get it. Put the allocation in the one helper that creates fake entries, so every example that uses the helper gets it.

Do not choose a "large enough" literal id or rely on the fake's own counter. Neither one stops the local sequence from catching up.

## Why it matters

An id-inequality check exists to catch a read that returns a local row in place of the owner's entry. If the two ids can be equal, the check gives false failures. Worse, the reverse check (`eq`) could pass while it reads the wrong row. Taking the id from the local sequence turns "the ids never meet" from a guess into a fact the database enforces.

## Evidence

- PR #259 changes the helper `owner_reads_create_timekeeping_entry` in `spec/requests/api/v1/time_tracking/owner_reads_spec.rb`. The helper now calls `nextval(pg_get_serial_sequence('timesheet_entries', 'id'))` and passes the result as `id:` to `fake_timekeeping.add_entry`.
- The comment added in the same file says the fake numbers its entries from 1001, which local `timesheet_entries` ids can also reach.
- The PR's test plan reproduced the failure by running `setval('timesheet_entries_id_seq', 1000, true)` before each example. With that setup the base failed with "Expected 1001 not to eq 1001". After the change, the file passed with and without that setup (7 examples, 0 failures). No assertion changed.
