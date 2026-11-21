---
module: Timekeeping ownership-state specs
date: 2026-11-21
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - spec/models/timesheet_entry_spec.rb
  - spec/policies/timesheet_entry_policy_spec.rb
  - spec/characterization/timesheet_entry_rules_spec.rb
tags:
  - timekeeping
  - ownership-state
  - owned-entry
  - projection
applies_when:
  - A model or policy spec is adapted to arrange entries with arrange_owned_entries.
  - A spec rule says to read entries back with owned_entry instead of TimesheetEntry.find or .reload.
---

# Find the arranged record as model and policy input, not as a read-back

## Context

In the Timekeeping and rollback ownership states, the `timesheet_entries` table is only a projection. The "owning store" is the store that holds the real entry in the selected state. Specs that check a stored outcome must read it from the owning store with `owned_entry(id, state: TimekeepingOwnerState.current)`.

That rule is easy to over-apply. `TimesheetEntry` callbacks and `TimesheetEntryPolicy` need a real `TimesheetEntry` object. `arrange_owned_entries` writes the same values to the projection in every state, so the projection record is the right input for them.

## Solution

Split each `TimesheetEntry.find` into one of two kinds before you change it:

- **Input to the operation.** The record goes into a model method, a validation or a policy check. Keep the find, by the arranged id. In this change, `arrange_model_entry` returns `described_class.find(arrange_owned_entries([...]).first)`, and `arrange_policy_entry` does the same with `TimesheetEntry.find`.
- **Read of a stored outcome.** The spec checks what a request left in storage. Move it to `owned_entry` and read fields with `.fetch("project_id")`, `.fetch("locked")` and so on, as the rules characterization spec now does.

A model save such as `update` or `discard!` on the found record writes the projection only. Do not re-point a read that follows such a save at the owner: the owner still holds the arranged values, so the check would fail or would only test the fixture. Keep these reads as they are, and report them with that reason instead of rewriting them.

## Why it matters

A blind swap of every `find` or `.reload` for `owned_entry` breaks model and policy specs, or turns them into checks of the fixture input. A spec that tests its own input still passes, but it no longer pins the callback it was written for.

## Evidence

PR #569 adds `arrange_model_entry` in `spec/models/timesheet_entry_spec.rb` and `arrange_policy_entry` in `spec/policies/timesheet_entry_policy_spec.rb`. Both return the projection record found by the arranged id and pass it to the model or policy under test.

In the same change, `spec/characterization/timesheet_entry_rules_spec.rb` replaces each `TimesheetEntry.find` read-back after a request with `owned_entry(..., state: TimekeepingOwnerState.current)`.

The PR body reports that the two `ensure_bill_status_is_set` examples keep `.reload` unedited. Its reason is that the model save they pin writes only `timesheet_entries`, so an owner read would change what they pin. The claim that model saves never reach the owner comes from the author's plan, not from the diff; check it against the callbacks in `app/models/timesheet_entry.rb` before relying on it.
