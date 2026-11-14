---
module: timekeeping-handoff
date: 2026-11-14
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - Timekeeping::Handoff::Runner
  - TimekeepingOwnership
  - TimekeepingHandoffFakeRelay
tags:
  - handoff
  - regression-spec
  - observer
  - final-outbox-position
  - mutation-check
applies_when:
  - A spec must prove that one handoff step clears a stored value that a later step writes again
  - A spec needs the owner's own drain to run inside a handoff
---

# Prove a mid-run clear with an observer read and a probe between the stale and new values

## Context

`Runner#close_admission` sets `final_outbox_position` to nil. That clear is the only protection against a position left by an earlier handoff. `TimekeepingOwnership#snapshot_generation_accepted?` trusts any stored position, and `Runner#freeze` reuses a stored position instead of capturing a new one. If the clear goes, a stale position quietly becomes this handoff's boundary and lets old-generation snapshots through.

A regression spec for this is easy to write so that it passes even with the clear deleted. Three traps cause that:

- Freeze writes a new position after close_admission. A check of the final row cannot tell whether the clear ever happened.
- If the stale and new positions are equal, or no checked position lies between them, the eligibility answers are the same with or without the clear.
- On the first cutover the drain is the legacy operations check, and the owner's `drain!` is never called. An eligibility check placed in the owner's drain never runs there.

## Solution

1. Run a cutover first, then seed the stale value with `update_columns`, then run a **rollback**. The rollback is the first direction that calls the owner's own drain.
2. Read the cleared value through the runner's `observer:` lambda at `(:after_step, step: "close_admission")`. Do not rely on the final row.
3. Make the stale value larger than the new one (here 40 and 5), and probe a position between them (6). With the clear in place the answers are accept, refuse, refuse for 5, 6, 40. Without it the boundary stays at 40, and 6 is accepted.
4. Check eligibility by calling the real `snapshot_generation_accepted?` from an inline subclass of `TimekeepingHandoffFakeRelay` that then calls `super`. Do not copy the rule into the fake.
5. Before you finish, delete the clear locally and confirm the spec goes red. Then restore it.

## Why it matters

The protection is one keyword argument in production code, and no other spec guards it at runner level. A spec that stays green when that argument is removed gives false confidence. The probe between the two values is what makes the spec fail. The mid-run observer read is the only place the clear is visible.

## Evidence

- PR #269 adds `spec/lib/timekeeping/handoff/runner_final_outbox_position_spec.rb`. The file seeds `stale_final_outbox_position = 40`, stubs `highest_outbox_position` to 5, and probes `[5, 6, 40]`. It expects `[["settle", 5, [true, false, false]]]`.
- The same file reads the row in an observer after `close_admission` and expects `[3, "close_admission", nil]`. Its comment says freeze overwrites the position, so the clear must be read right after step 1.
- Its comment states that the first cutover drains through the legacy check, so only the rollback reaches the owner's drain.
- The PR #269 description reports that, with `final_outbox_position: nil` removed from `Runner#close_admission`, the spec failed because the row after close_admission held 40.
