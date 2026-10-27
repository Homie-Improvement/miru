---
module: timekeeping handoff
date: 2026-10-27
problem_type: design_pattern
component: timekeeping_ownership
severity: high
evidence_grounding: anchored
grounding_evidence: "In PR #197, app/models/timekeeping_ownership.rb changes snapshot_generation_accepted? from a frozen_for_handoff? step check to 'return false if handoff_step.nil? || final_outbox_position.nil?', and lib/timekeeping/handoff/runner.rb clears final_outbox_position in close_admission and stores it in freeze before drain!."
audience: both
related_components:
  - projection_consumer
  - handoff_runner
tags:
  - handoff
  - outbox
  - generation
  - resumable-steps
applies_when:
  - A step records its progress label only after its work finishes
  - That work needs a permission that another component grants by reading the ownership row
---

# Gate a step's own permission on the data it stores, not on the step it records

## Context

The handoff runner records `handoff_step` only after a step's work has committed and its completion check passed. That rule makes resume safe: an unfinished step stays unrecorded and runs again.

The freeze step drains the outgoing owner's outbox through a final position P. Those outbox rows carry the previous generation, because step 1 already raised it. The projection consumer accepts previous-generation rows only when `TimekeepingOwnership#snapshot_generation_accepted?` says yes.

Before this change, that check required `handoff_step` to be `freeze` or later. But `freeze` is recorded only after the drain. So the drain could never deliver: the consumer refused every batch, and the handoff stayed fenced forever.

## Solution

Open the permission on the data the step writes first, not on its label:

- Step 1 (`close_admission`) clears `final_outbox_position` in the same transaction that raises the generation.
- Freeze stores P in its own transaction (still at step `settle`), then drains through P, then the interpreter records `freeze`.
- `snapshot_generation_accepted?` accepts the previous generation while `handoff_step` is present and `final_outbox_position` is not null, up to P.

Clearing P at step 1 matters. Without it, a P left from an earlier handoff would open the permission before this handoff has captured its own.

## Why it matters

"Record progress last" and "gate permissions on recorded progress" contradict each other when the permission is needed by the step's own work. The result is a step that can never finish. The old predicate tests only covered the recorded steps, so they passed. The fault shows once a test asserts acceptance while the step is still `settle` with P stored. When you add a step whose work depends on a permission, ask which stored fact the step writes first, gate on that fact, and test the predicate in the state the step's work actually runs in.

## Evidence

- PR #197, `app/models/timekeeping_ownership.rb`: the private `frozen_for_handoff?` step check is removed, and the comment explains that the stored P, not the recorded step, opens the permission.
- PR #197, `lib/timekeeping/handoff/runner.rb`: `close_admission` updates `final_outbox_position: nil` with the generation raise; `freeze` calls `store_final_outbox_position` with `expected_step: "settle"` before `drain!`.
- PR #197, `spec/models/timekeeping_ownership_spec.rb`: new examples accept generation 2 at position 40 while `handoff_step` is `settle` with P stored, and refuse it when P is null or `handoff_step` is null.
