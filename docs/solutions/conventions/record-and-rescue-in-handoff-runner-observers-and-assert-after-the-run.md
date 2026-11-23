---
module: timekeeping
date: 2026-11-23
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - timekeeping-handoff
  - live-handoff
tags:
  - handoff-runner
  - observer
  - close-admission
applies_when:
  - "A spec passes an observer: to Timekeeping::Handoff::Runner.run or run_live_handoff to act between handoff steps"
---

# Record and rescue in handoff runner observers, and assert after the run

## Context

`Timekeeping::Handoff::Runner.run(observer:)` calls the observer with step events, such as `:after_step` for `"close_admission"`. A spec can use this hook to act in the middle of a handoff. For example, it can send edits while admission is closed.

The comment added in PR #572 states that the runner does not rescue its observer. A failed `expect` or any other error raised inside the hook leaves the handoff fenced. It also skips the checks that run after the handoff.

## Solution

- Make the observer only record what it sees into a plain hash: a `fired` flag, the replies, and the counts.
- End the hook with `rescue StandardError => e` and store the error message. Do not re-raise it.
- After `run_live_handoff` returns, assert that there was no error and that `fired` is true. Then judge each recorded reply.
- Pass the observer through `run_live_handoff(direction, company_ids:, observer:)`, not through a direct `Runner.run` call. This keeps the owner, generation, `handoff_step` and reconciliation checks for the run that has the hook. The keyword defaults to `Timekeeping::Handoff::NullObserver.new`, so existing callers keep their behavior.
- Match the step name as a String, `"close_admission"`.

## Why it matters

An expectation inside the hook fails at the worst point. The handoff is left half done, and the error hides the state you need to debug it. Checking `fired` after the run also catches a hook that never ran, which would otherwise pass with no assertions.

## Evidence

- PR #572, `spec/integration/timekeeping/alternating_writers_spec.rb`: `paused_edit_observer` records into `pause`, rescues `StandardError`, and its comment states that the runner does not rescue its observer. The example then checks `pause[:error]` and `pause[:fired]` after `run_alternating_handoff(:cutover, ...)`.
- PR #572, `spec/support/timekeeping/live_handoff.rb`: `run_live_handoff` gains `observer: Timekeeping::Handoff::NullObserver.new` and forwards it to `Runner.run`.
- The claim that the runner does not rescue its observer comes from the spec's comment. The runner's code is not part of this change. To confirm it, read `carry_out` in `lib/timekeeping/handoff/runner.rb`.
