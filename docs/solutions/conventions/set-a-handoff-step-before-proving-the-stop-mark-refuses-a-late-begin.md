---
module: timekeeping handoff
date: 2026-11-19
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - app/models/timekeeping_ownership.rb
  - lib/timekeeping/handoff/runner.rb
tags:
  - settling-stopped-generation
  - begin-settling
  - vacuous-assertion
  - handoff-specs
applies_when:
  - A spec checks that `TimekeepingOwnership.begin_settling!` is refused after a handoff ends
  - A spec proves a stop mark or similar guard when other guards can refuse the same call
---

# Set a handoff step before proving the stop mark refuses a late begin

## Context

The ownership row has a stop mark, `settling_stopped_generation`. It exists so that a late `begin_settling!` from an earlier handoff cannot reopen an old settle step. Reopening would let stale commits at that generation be applied again.

The stop mark is not the only thing that can refuse `begin_settling!`. A begin is also refused when no handoff is in progress, which means `handoff_step` is NULL. When `flip` or `abort_handoff` ends a handoff, it sets `handoff_step` to NULL. So a spec that runs a late `begin_settling!(generation: 1)` right after the run sees it refused whether or not the stop mark was raised. That spec passes without the fix it claims to test.

## Solution

Before the late begin, put the row in a later handoff, so the stop mark is the only check that can refuse it:

```ruby
# A later handoff is in progress, so only the stop mark can refuse the late begin.
TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID).update_all(handoff_step: "settle")
TimekeepingOwnership.begin_settling!(generation: 1)
expect(TimekeepingOwnership.current.settling_generation).to be_nil
```

Then check the other side. A begin at a newer generation must still open, which proves the mark was not raised too far:

```ruby
TimekeepingOwnership.begin_settling!(generation: 2)
expect(TimekeepingOwnership.current.settling_generation).to eq(2)
```

These specs commit their writes. Their `ensure` block must reset `handoff_step` as well as `settling_generation` and `settling_stopped_generation`. If it does not, the raised mark and the planted step leak into later examples.

## Why it matters

A refusal assertion only proves something when the guard under test is the only possible reason for the refusal. If another guard also refuses, the assertion passes with or without the fix, and a future regression in the stop mark goes unnoticed. Asserting that a newer generation still opens catches the opposite mistake: a mark set to the row's current `generation` instead of the cleared step's generation would block the next handoff's own settle step.

To confirm such a spec is not vacuous, replace `row.close_settling_step` with `row.settling_generation = nil` in one transition at a time, and check that the spec for that transition fails.

## Evidence

- PR #416 changes `spec/lib/timekeeping/handoff/runner_spec.rb`. In both the flip example and the abort example, it sets `handoff_step: "settle"` with `update_all` before `begin_settling!(generation: 1)`. Its comment says that only the stop mark can refuse the late begin while a later handoff is in progress.
- In the same file, the flip example asserts that `begin_settling!(generation: 2)` opens, with the comment that the mark is the cleared generation, not higher.
- Both `ensure` blocks in that file now reset `handoff_step: nil` along with the two settling columns.
- The fix under test is in `lib/timekeeping/handoff/runner.rb`, where `flip` and `abort_handoff` call `row.close_settling_step`, and in `app/models/timekeeping_ownership.rb`, where `SettlingPhase.close` raises the mark to the open step's generation.
