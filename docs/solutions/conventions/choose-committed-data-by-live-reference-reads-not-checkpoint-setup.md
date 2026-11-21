---
module: Timekeeping ownership-state specs
date: 2026-11-21
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - spec/support/timekeeping/owned_entries.rb
  - spec/characterization/timesheet_entry_rules_spec.rb
tags:
  - timekeeping
  - checkpoint
  - committed-data
  - test-isolation
applies_when:
  - A spec uses arrange_owned_entries with the live Timekeeping app.
  - An ownership-state adaptation needs a decision about committed reference fixtures.
---

# Choose committed fixtures from the live operation's reads

## Context

Do not add `committed_data: true` solely because `arrange_owned_entries` loads fixtures into the live Timekeeping app.

A separate database connection cannot see reference rows held in an uncommitted transaction. That matters when the live operation reads those rows. It does not follow merely from sending a checkpoint to another app.

The model and policy specs arrange entries through a checkpoint, then exercise a local `TimesheetEntry` object. Their live checkpoint setup works without committed reference fixtures. The request characterization spec needs committed company, user and project rows for its live operations.

## Solution

Choose transaction setup from the reads performed by the operation:

- Keep normal transaction setup for the model and policy examples covered here. Their checkpoint load alone does not justify committed fixtures.
- Use `committed_data: true` when the live operation needs to read monolith reference rows through another connection.
- Recheck that decision when an example changes from a local model or policy operation to a live request.

Trace the actual route before copying transaction metadata from a neighboring request spec. Then run the affected file with `TIMEKEEPING_OWNER_STATE=timekeeping`, `TIMEKEEPING_REGRESSION=1` and `TIMEKEEPING_LIVE=1`. Use a `_test` `TIMEKEEPING_DATABASE_URL` so the check exercises the real app safely.

## Why it matters

Unnecessary committed fixtures change test isolation without establishing a need. Missing committed fixtures can instead make a live request unable to find its reference rows. The deciding fact is which connection reads the rows, not whether setup contacts the live app.

## Evidence

PR #569 adds checkpoint-backed arrangement helpers to `spec/models/timesheet_entry_spec.rb` and `spec/policies/timesheet_entry_policy_spec.rb` without adding `committed_data: true` groups there.

The same change adds `committed_data: true` to `spec/characterization/timesheet_entry_rules_spec.rb`. Its comment explains that live operations read company, user and project rows through the app's own database connections.

The recorded verification ran these three files together in the timekeeping state with the live app booted. It returned `90 examples, 0 failures` without adding committed-data metadata to the model or policy specs.
