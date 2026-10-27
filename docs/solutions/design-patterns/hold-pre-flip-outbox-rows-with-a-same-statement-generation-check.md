---
module: timekeeping
date: 2026-10-27
problem_type: design_pattern
component: outbox_relay
severity: high
evidence_grounding: anchored
grounding_evidence: "In PR #197, timekeeping/app/services/timekeeping/relay_outbox_source.rb adds HELD_GENERATION_EXCLUSION as a subquery on admission.held_generation, and timekeeping/app/models/timekeeping/admission.rb adds hold_generation! and changes admit! to delete unsent rows of a different held generation; held_correction_snapshots_spec.rb tests both."
audience: both
related_components:
  - admission
  - correction_snapshots
  - handoff_runner
tags:
  - outbox
  - relay
  - generation
  - handoff
  - abort-retry
applies_when:
  - A handoff writes outbox rows at a new generation before ownership flips to the writer
  - An attempt can be aborted and retried at a later generation
---

# Hold pre-flip outbox rows, and read the hold in the same statement as the rows

## Context

A first cutover writes correction snapshots into Timekeeping's outbox during step 4, before the flip makes Timekeeping the owner. Two things went wrong with those rows.

1. Delivered early, they change `timesheet_entries`, which is also the frozen legacy source. A resumed handoff then rebuilds a different source and refuses.
2. If the attempt is aborted, its undelivered rows stay in the outbox. The correction writer replaces rows only within one generation. After a retry flips at a later generation, the consumer refuses the old rows, and one refused batch stops the relay for every later change.

The runner's in-memory test fake replaced corrections across generations, so it hid the second problem.

## Solution

- Add `admission.held_generation`. `Admission.hold_generation!` sets it inside the transaction that writes the correction rows.
- `RelayOutboxSource#unsent_after` excludes rows of the held generation with a subquery in the same SQL statement as the row read. A separate read of the hold could miss a write that commits between the two reads.
- `hold_generation!` at a new generation deletes unsent rows of the previous held generation. `admit!` releases the held generation when it matches, and deletes its unsent rows when a different generation is admitted.

## Why it matters

Any outbox that a not-yet-owner writes to needs a release point tied to the ownership flip, and a cleanup tied to abandonment. Without the release point, delivery changes data a resume must re-read unchanged. Without the cleanup, one aborted attempt can stop the relay permanently. Prove both with the real writer and relay source, not a fake that is more forgiving than the real store.

## Evidence

- PR #197, `timekeeping/app/services/timekeeping/relay_outbox_source.rb`: `HELD_GENERATION_EXCLUSION` and its comment on reading the hold in one statement.
- PR #197, `timekeeping/app/models/timekeeping/admission.rb`: `hold_generation!`, `held_generation`, and the new body of `admit!`.
- PR #197, `timekeeping/app/services/timekeeping/handoff/correction_snapshots.rb`: `write!` calls `Admission.hold_generation!(generation)` in its transaction.
- PR #197, `timekeeping/spec/services/timekeeping/handoff/held_correction_snapshots_spec.rb`: rows are not offered until admitted; a retry at generation 3 leaves only generation 3 pending; a hold that commits while the relay reads is never offered.
- The author reported the full Timekeeping suite at 626 examples, 0 failures for this fix.
