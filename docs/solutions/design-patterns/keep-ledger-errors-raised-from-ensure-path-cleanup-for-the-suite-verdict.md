---
module: Timekeeping proof harness
date: 2026-11-19
problem_type: design_pattern
component: testing_framework
severity: medium
audience: both
related_components:
  - IntegratedRuntime
  - TimekeepingQueueLedger::Session
tags:
  - ensure
  - error-masking
  - queue-ledger
  - teardown
applies_when:
  - Adding a check or a recording step to a cleanup method that callers run from an ensure block
  - Changing IntegratedRuntime#stop! or TimekeepingQueueLedger::Session#after_stop!
---

# Keep ledger errors raised during ensure-path cleanup for the suite verdict

## Context

`IntegratedRuntime#stop!` runs from `boot!`'s `ensure` and from `IntegratedRuntime.run`'s `ensure`. So it often runs while a boot error or a test failure is already being raised.

In Ruby, an exception raised inside `ensure` replaces the one already being raised. The original error is lost.

The queue ledger first collected Solid Queue executions directly in `stop!`. A `CollectError` (for example, an unreachable Timekeeping database) would then replace the `BootError`. `CollectError` is raised with `cause: nil` so that no database URL leaks. This means the real boot failure was not even attached as a cause.

## Solution

A step that `stop!` calls must never raise. It keeps its errors for the end-of-suite verdict instead:

```ruby
def after_stop!
  [step_error { collect! }, step_error { observe_controls! }].compact.each { |error| @stop_errors << error }
  nil
end
```

`finish!`, which runs in the single after(:suite) hook, adds `@stop_errors` to its list of problems and raises one `RunFailed` that names all of them. The failure still makes the run exit non-zero, but it surfaces where nothing else is being raised.

Use the same rule for any new step you add to `stop!` or to another method that callers run from `ensure`: run it through `step_error`, store the result, and report it from `finish!`.

## Why it matters

If this rule is broken, a run that fails to boot reports a ledger problem instead of the boot problem. The engineer then debugs the wrong failure. The ledger error still matters, so it must not be swallowed either. Storing it for `finish!` keeps both errors.

## Evidence

- PR #393, `spec/support/timekeeping/queue_ledger.rb`: `Session#after_stop!` wraps `collect!` and `observe_controls!` in `step_error` and appends to `@stop_errors`; `finish!` includes `@stop_errors` in the `RunFailed` message.
- PR #393, `spec/support/timekeeping/integrated_runtime.rb`: `stop!` ends with `@ledger.after_stop!`.
- PR #393, `spec/meta/timekeeping_queue_ledger_spec.rb`: the example "a boot error raised before stop! reaches the caller even when the ledger collector fails in stop!" raises `IntegratedRuntime::BootError` with `session.after_stop!` in `ensure`, and expects the `BootError`. The example "after_stop! keeps a collector error for finish! instead of raising it" expects `finish!` to raise `RunFailed` naming "monolith unreachable".
- The build review of this pull request found the earlier version, where `stop!` called `collect!` directly, and the fix replaced it.
