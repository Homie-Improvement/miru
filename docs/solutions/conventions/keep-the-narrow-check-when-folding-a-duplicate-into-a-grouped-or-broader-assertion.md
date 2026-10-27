---
module: spec/services/imports
date: 2026-10-27
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: anchored
grounding_evidence: "In PR #224, spec/services/imports/harvest_time_entries_importer_spec.rb adds rerun order and count checks beside the existing by-note grouping, and keeps the note: \"same work\" count beside the new count of all the user's entries."
audience: both
related_components:
  - imports
  - timekeeping
tags:
  - duplicate-tests
  - spec-consolidation
  - assertion-coverage
  - deliberate-break
applies_when:
  - Deleting a near-duplicate example after moving its checks into a surviving example
  - The surviving example groups results by a key, or counts a wider set than the duplicate did
---

# Keep the narrow check when you fold a duplicate into a grouped or broader assertion

## Context

When two examples test the same rule, you delete one and move its checks into the one you keep. Sometimes the kept example already has a check that looks stronger than the duplicate's check. That check often only looks stronger.

Two cases came up in the Harvest importer spec:

- **Grouping hides order and count.** The kept forwarded-rerun example grouped the rerun's create requests by note (`keys_by_note`). The duplicate checked the rerun's requests in the order they were sent: exactly two creates, unique keys, and the first create reusing the first run's key. A grouping by note cannot see request order. So an importer that sorted rows the other way on a retry would still pass the grouped check.
- **A wider count drops a filter.** The legacy generation example counted entries with `note: "same work"`. The change added a count of every entry for the user, which catches a stray extra write. Replacing the note count with the wider count would lose a check. If the one entry stored before the rerun had the wrong note, the rerun could still write both expected rows, and the final count (filtered by note and source) would pass with the bad entry still stored.

## Solution

- Move every check the duplicate makes. Treat a check in the kept example as covering it only when that check can see the same property: order, count, or field value.
- When you add a wider check, add it **beside** the narrow one. Do not swap them.
- Before you delete the duplicate, break the code under test in the one way only the duplicate's check would catch. Confirm the kept example fails, then undo the break. In PR #224 the breaks were: send the remaining rows in reverse order on a rerun, resend a create, and rescue `StaleGeneration` or `OwnershipMoving` as a row error. If the kept example passes under a break, keep the duplicate.

The kept rerun example now has both checks:

```ruby
# Grouping by note hides how many creates the rerun sent and in what order, so check its own creates too.
rerun_posts = posts.drop(first_run_keys.size)
rerun_keys = rerun_posts.map { |request| request[:headers]["Idempotency-Key"] }
expect(rerun_keys.size).to eq(2)
expect(rerun_keys.uniq.size).to eq(2)
expect(rerun_keys.first).to eq(first_run_keys.first)
expect(rerun_posts.map { |request| request[:body]["note"] }).to eq(["first row", "second row"])
```

The generation example keeps both counts:

```ruby
expect(TimesheetEntry.where(user: fold_gen_paul).count).to eq(1)
expect(TimesheetEntry.where(user: fold_gen_paul, note: "same work").count).to eq(1)
```

## Why it matters

A tidy-up of tests should change how they are arranged, not what they check. A wider or grouped check reads as stronger, so a reviewer passes the swap without a second look. Then the suite stops catching a bug it used to catch, and nothing fails to tell you. A deliberate break is the only cheap way to show that the check you dropped is really covered.

## Evidence

- PR #224, `spec/services/imports/harvest_time_entries_importer_spec.rb`: the forwarded rerun example adds the `rerun_posts` order and count checks next to the existing by-note grouping. The duplicate `rerun_` describe block, which had the order checks, is deleted.
- The same file: the legacy generation example adds `TimesheetEntry.where(user: fold_gen_paul).count` and keeps the `note: "same work"` count beside it. A code review of the change asked to restore the note count after it had been replaced.
- The PR body reports the breaks run against each kept example. The rerun example failed on reversed row order and on a resent create. The generation and handoff examples failed when the refusal was rescued as a row error.
