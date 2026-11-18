---
module: timekeeping
date: 2026-11-18
problem_type: design_pattern
component: admission
severity: medium
audience: both
related_components:
  - reservation_operations
  - handoff
tags:
  - settle-step
  - stop-mark
  - high-water-mark
  - late-requests
  - generation
applies_when:
  - A stored phase can be ended by more than one call, such as an explicit stop and an admit
  - A column that only rises guards against late or retried calls reopening that phase
---

# Raise the stop mark in every transition that closes a settle step

## Context

During a handoff, Timekeeping's `admission` row is fenced (`generation` is NULL). A settle step lets it still finish commits and aborts it registered at the outgoing generation. `settling_generation` names the open step. `settling_stopped_generation` is a stop mark: the highest generation whose step was ended.

The mark exists because a timed-out HTTP request can still run on the server later. `SettlingPhase.begin` refuses to open a step at or below the mark, so a late `begin_settling!` cannot reopen a stopped step.

The first version raised the mark only in `stop_applying!`. `admit!` cleared `settling_generation` but left the mark alone. So this sequence reopened an old step: `fence!`, `begin_settling!(5)`, `admit!(6)` with no stop, `fence!` again, then a late `begin_settling!(5)`. `begin` saw no open step and no mark, and opened generation 5 during the newer handoff. Commits at 5 would then apply and write outbox snapshots at a superseded generation.

## Solution

Any call that ends a step must raise the mark to that step's generation, in the same statement that clears the step. `admit!` now does:

```ruby
where(id: SINGLETON_ID).update_all(
  "settling_stopped_generation = GREATEST(settling_stopped_generation, settling_generation), " \
  "settling_generation = NULL"
)
```

PostgreSQL's `GREATEST` ignores NULLs. So the mark rises to the open step's generation when there is one, and otherwise stays as it was. It never falls.

When you add a new way to end the phase, list it beside `stop_applying!` and `admit!` and make it raise the mark too. Test reset code is the only place that may lower the mark.

## Why it matters

A high-water mark protects only the transitions that write it. If one closing path skips it, the guard has a hole that shows up only across two handoffs, with a late request in between. That is the exact timing the mark was added for, and it is rare in tests and common in production retries.

The mark is kept on purpose across `admit!`. Specs that commit admission changes must therefore reset it themselves, or a stop mark from one example blocks a settle in the next.

## Evidence

- PR #372 changes `timekeeping/app/models/timekeeping/admission.rb`: `admit!` now runs the `GREATEST(settling_stopped_generation, settling_generation)` update, and its comment says the mark never falls so a late settle cannot reopen a step after a later fence.
- In the same file, `SettlingPhase.begin` returns nil unless `settling_stopped_generation` is nil or below the requested generation.
- `timekeeping/spec/models/timekeeping/admission_spec.rb` adds the example "admit! ending an unstopped settle step keeps a late begin_settling! for that generation from reopening it": after `admit!(6)` the mark is 5, and a later `begin_settling!(generation: 5)` leaves `settling?` false.
- The review finding on this pull request reported the reopen sequence. The author's check ran it in a rolled-back transaction and got `[false, 5]` after the fix.
- `timekeeping/spec/support/entry_write_context.rb` resets both settling columns in the non-transactional after hook, with the comment that `admit!` keeps the stop mark on purpose, so only a test resets it.
