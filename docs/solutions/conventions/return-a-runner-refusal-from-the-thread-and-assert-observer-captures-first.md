---
module: timekeeping handoff specs
date: 2026-11-21
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - timekeeping
tags:
  - removal-check
  - observer
  - handoff-runner
  - mutation-proof
applies_when:
  - A spec captures state in a handoff observer hook and asserts on it after the run
  - A removal check must show that a specific assertion fails when a step is removed
---

# Return a runner refusal from the thread, and assert observer captures first

## Context

`Timekeeping::Handoff::Runner` checks each step once it finishes. If the check fails, the runner raises `Runner::Refused`. So when a removal check takes out the call to `settle_integration.settle!`, the run stops before the `[:before_step, "freeze"]` hook. The observer never captures the freeze state. If the spec simply lets the exception escape, it fails on the exception. It does not fail on the freeze assertion the removal is meant to prove.

## Solution

- Run the handoff on a thread that rescues `Timekeeping::Handoff::Runner::Refused` and returns it as the thread's value. If the run reaches the flip, the thread returns `nil`.
- Have the observer only capture state. Make every assertion after `thread.value`.
- Assert the captured state first, for example `captured[:freeze]` against the settled shape. A missing capture is `nil`, so this assertion fails with its own message. Put `refusal&.message` in that message.
- Only after that, assert `expect(refusal).to be_nil` and check the final owner.
- Leave the runner's own completion check unchanged. The spec changes only the order in which it reads the outcome.

## Why it matters

A removal record is useful only when it names the assertion that the removed code protects. If the spec fails on an exception, a reader cannot tell whether the freeze assertion discriminates at all. The same pattern applies to any hook-based capture that a guarded runner can stop short of.

## Evidence

- In PR #537, `concurrency_rollback_thread` in `spec/integration/timekeeping/handoff_concurrency_spec.rb` rescues `Timekeeping::Handoff::Runner::Refused => refusal` and returns it.
- The in-flight example asserts `captured[:freeze]`, with the message "at the freeze the in-flight operation was not settled (#{refusal&.message})", before `expect(refusal).to be_nil`.
- The PR #537 description records that removing the `settle!` call gave that freeze message.
