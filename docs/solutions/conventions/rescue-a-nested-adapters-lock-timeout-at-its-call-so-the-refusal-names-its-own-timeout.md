---
module: timekeeping_handoff
date: 2026-11-18
problem_type: convention
component: timekeeping_handoff
severity: low
audience: both
related_components:
  - lib/timekeeping/handoff/runner.rb
  - lib/timekeeping/handoff/monolith_admission.rb
tags:
  - lock-timeout
  - error-messages
  - handoff
  - operator-diagnosis
applies_when:
  - A runner step calls an adapter that sets its own SET LOCAL lock_timeout and can raise ActiveRecord::LockWaitTimeout
  - The step already rescues LockWaitTimeout for its own row update and quotes its own timeout in the message
---

# Rescue a nested adapter's lock timeout at its call so the refusal names that adapter's timeout

## Context

`Runner#close_admission` in `lib/timekeeping/handoff/runner.rb` does two waits that can time out. First, it calls the outgoing owner's `fence_admission`. Then it updates the ownership row under `close_admission_lock_timeout`. A lock timeout makes PostgreSQL stop waiting for a row lock. Rails then raises `ActiveRecord::LockWaitTimeout`.

The method already had one rescue at its end. That rescue raises a refusal that quotes `@close_admission_lock_timeout`. `Timekeeping::Handoff::MonolithAdmission#fence_admission` waits under its own `FENCE_LOCK_TIMEOUT` of 60 seconds. If the fence ran out of time, the method-level rescue still blamed close_admission's timeout. The handoff still failed closed, but the message was wrong. An operator who raised `close_admission_lock_timeout` would change nothing.

## Solution

Wrap the adapter call in its own method with its own rescue. This keeps the step's rescue for its own update:

```ruby
def fence_monolith_admission
  outgoing.admission.fence_admission
rescue ActiveRecord::LockWaitTimeout
  raise Refused, "Monolith writes still hold the ownership row past the monolith admission fence's lock " \
                 "timeout; resume or abort the handoff"
end
```

The rule: when one method runs several waits under different timeout settings, each rescue covers only the call that uses its own setting. The message names that setting and quotes no other.

## Why it matters

A refusal message tells the operator what to fix. Rescuing at the method level still refuses correctly, so tests that check only the refusal type keep passing. The wrong text shows up only during an incident, and then it sends the operator to tune a setting that cannot help. Pin the message in a spec: make the inner wait time out, and assert that the message does not include the outer timeout.

## Evidence

- PR #375 adds `fence_monolith_admission` to `lib/timekeeping/handoff/runner.rb`, with a comment saying that quoting the runner's timeout would send an operator to tune the wrong setting.
- `lib/timekeeping/handoff/monolith_admission.rb` defines `FENCE_LOCK_TIMEOUT = 60.seconds` and applies it through `SET LOCAL lock_timeout` inside `fence_admission`. This timeout is separate from the runner's `close_admission_lock_timeout`.
- In `spec/lib/timekeeping/handoff/monolith_admission_spec.rb`, the example "reports a monolith fence timeout as the fence's own, not as close_admission's lock timeout" keeps a FOR SHARE lock on the ownership row and runs the runner with `close_admission_lock_timeout: 7.seconds`. It asserts that the message matches `/monolith admission fence/` and does not include `7.seconds.inspect`.
- A build review of this pull request raised the misattribution as a finding. The author fixed it in this diff and reported that the admission and ownership specs passed with 0 failures.
