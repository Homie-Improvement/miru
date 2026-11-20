---
module: timekeeping
date: 2026-11-20
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - timekeeping_handoff
tags:
  - postgres-sequence
  - mutation-sensitivity
  - live-specs
applies_when:
  - A spec must fail if code that advances an id sequence past loaded rows is removed
---

# Arrange a row at the sequence's next value to prove a sequence advance

## Context

After loading rows with explicit ids, the Timekeeping helper calls `advance_entry_id_sequence(above:)` so a later API create gets a fresh id. A test that arranges only an id above the sequence's next value cannot catch removal of that call. The next create takes the next value, which no arranged row holds, so it succeeds either way.

The next value is also not fixed. The live reset truncates without restarting identities, so the sequence keeps rising across examples.

## Solution

Read the next value at runtime, then arrange a row at exactly that value, beside any row the requirement names:

```ruby
next_id = store.advance_entry_id_sequence(above: 0)
arrange_owned_entries([{ ..., id: next_id + 5 }, { ..., id: next_id }], state: "timekeeping")
```

Then create through the API and assert that the new id is not an arranged id and that all three ids exist in the Timekeeping database. Without the advance, the create draws `next_id` and collides with the arranged row.

Keep the row the requirement asked for. Adding the next-value row makes the test sensitive without dropping the requested case.

## Why it matters

A boundary test whose input never reaches the boundary passes against broken code. For sequence advances, the boundary is the exact next value.

## Evidence

- PR #473 adds the live example "live API create after arranging ids above and at the sequence's next value gets a new id and keeps every row" in `spec/integration/timekeeping/owned_entries_spec.rb`. It arranges `next_id + 5` and `next_id` in one batch.
- The helper under test is `spec/support/timekeeping/owned_entries.rb`, which calls `advance_entry_id_sequence(above:)` in `load_while_fenced`.
- Verification step to run: the live examples skipped in the PR's reported run (4 pending without the live flags). Run them with `TIMEKEEPING_LIVE=1` and `TIMEKEEPING_REGRESSION=1`, remove the advance call, and confirm the example fails.
