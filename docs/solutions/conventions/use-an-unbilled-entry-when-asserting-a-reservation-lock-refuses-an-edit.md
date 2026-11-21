---
module: timekeeping
date: 2026-11-21
problem_type: convention
component: testing_framework
severity: high
audience: both
related_components:
  - timesheet_entries
  - invoices
tags:
  - reservation-lock
  - false-pass
  - billed-entries
  - integration-specs
applies_when:
  - A spec asserts that an employee edit of a timesheet entry is refused because the entry is reserved
  - A spec reuses entries from db/seeds.rb to check a lock
---

# Use an unbilled entry when you assert that a reservation lock refuses an edit

## Context

After cutover, Timekeeping refuses an employee edit of an entry that an invoice reserves. The answer is a 4xx status. But the timesheet entry edit policy also refuses billed entries, whatever their reservation. The seed bills every entry it puts on an invoice. For Copper Kettle, that is every entry the seed creates.

A refused edit looks the same whichever rule refused it. So a lock check on a seeded entry passes even when reservation locking is broken.

## Solution

In each example, create the entries the lock check reads. A seeded employee of the company creates them through the timesheet entry API, dated today and with `bill_status: :unbilled`. Then the only rule that can refuse the edit is the reservation lock. The billed rule cannot, and neither can the edit-window rule for old entries.

To make a "non-draft holding X", save a new draft with a line on X, then set its status to `sent` directly. A live non-draft sends no reservation operation, so X stays reserved by it and stays unbilled.

Then prove that the check depends on the lock. Force the lock off for one run, confirm the lock checks fail, and restore the code.

## Why it matters

These checks guard invoiced time. If a lock regression goes unseen, an employee can edit time on an invoice. A lock test that any refusal satisfies proves nothing about the lock.

## Evidence

- PR #541 adds `spec/integration/timekeeping/section_9_3_spec.rb`. Its header comment says the seed bills every invoiced entry and that the edit policy refuses billed entries whatever their reservation. So each example creates fresh, unbilled entries after cutover.
- In the same file, `section_9_3_fresh_entry` posts `bill_status: :unbilled` through `api_v1_timesheet_entry_index_path`. `section_9_3_non_draft_holding` sets a held draft to `sent` with `update!`.
- The PR #541 description reports a check the author ran. With `locked:` forced to false in Timekeeping's entry writer, the three lock examples failed for both companies with "edit answered 200, not a refusal". The file was then restored.
