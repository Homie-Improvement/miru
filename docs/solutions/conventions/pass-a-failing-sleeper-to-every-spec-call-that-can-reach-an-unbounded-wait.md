---
module: timekeeping_handoff
date: 2026-11-21
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - lib/timekeeping/handoff/runner.rb
  - spec/lib/timekeeping/handoff
tags:
  - injected-sleeper
  - poll-loop
  - hanging-spec
  - timekeeping-handoff
  - abort
applies_when:
  - Code polls until a check passes, has no timeout, and sleeps through an injected callable
  - An existing spec used to expect a refusal from a call that now waits instead
---

# Pass a failing sleeper to every spec call that can reach an unbounded wait

## Context

`Timekeeping::Handoff::Runner.run` now takes a `sleeper:` keyword, which defaults to `Kernel.method(:sleep)`. An abort uses it to wait for an incomplete settle or freeze step. On each round it calls `sleeper.call(ABORT_POLL_INTERVAL)` (5 seconds), then runs the step and its completion check again. The wait has no timeout on purpose. A timeout would make the abort refuse again, and the design says abort waits.

That means a spec that calls `run(abort: true)`, passes no sleeper, and reaches a step whose completion check never passes gets real 5-second sleeps in a loop with no end; an abort whose owed steps complete returns without sleeping. Before this change, an incomplete step raised `Runner::Refused`, so a regression made the example fail. After it, the same regression makes the example sleep 5 seconds per poll until the CI job is killed. No example fails, and no message names the cause.

## Solution

Give every spec call that can enter the wait a sleeper that fails loudly. Pick the kind by what the example expects:

- **No wait expected** (the step is already complete): pass a sleeper that raises on its first call.
  ```ruby
  def incomplete_check_no_wait_sleeper = ->(_seconds) { raise "no wait expected once the step completes" }
  ```
- **A wait expected** (the example changes the world on poll N): count the calls and raise once the count passes a cap that is larger than any example needs.
  ```ruby
  def abort_wait_poll_cap = 10

  def abort_wait_sleeper(sleeps, &on_poll)
    cap = abort_wait_poll_cap
    lambda do |seconds|
      sleeps << seconds
      raise "the abort was still waiting after #{cap} polls" if sleeps.size > cap

      on_poll&.call(sleeps.size)
    end
  end
  ```
- **An operator interrupt** (proving that a stopped wait leaves the row fenced): pass a sleeper that raises a spec-local error class, and expect that error.

Apply this to calls that already existed, too. A call that used to expect `Refused` is the easiest one to miss, because it can keep passing with the real sleep until a later regression.

Forward and resume runs never wait. Passing them a raising sleeper also proves they did not start to wait.

## Why it matters

A loop with no end in production code is a choice the code makes on purpose. In a spec, the same loop is a hang waiting to happen. A sleeper that raises turns "the step never completed" into a failing example with a clear message. It also removes real sleeps from the suite. The cap costs nothing in a passing run, because the example finishes long before it.

## Evidence

PR #530 adds the unbounded wait in `lib/timekeeping/handoff/runner.rb`: `carry_out(names, wait_until_complete: true)` loops `until step_completed?(step)` and calls `@sleeper.call(ABORT_POLL_INTERVAL)`, and `sleeper: Kernel.method(:sleep)` is the default in `Runner.run`. A build review of this pull request found that the completing abort calls in the four edited examples of `spec/lib/timekeeping/handoff/runner_incomplete_checks_spec.rb` passed no sleeper, so a regression would hang the suite. The fix passes `incomplete_check_no_wait_sleeper` to each of those calls. It also adds the 10-poll cap (`abort_wait_poll_cap`) to every counting sleeper in `spec/lib/timekeeping/handoff/runner_abort_wait_spec.rb`. The author ran `bundle exec rspec` on both spec files and got 9 examples, 0 failures, with the completing aborts finishing without calling the raising sleeper.
