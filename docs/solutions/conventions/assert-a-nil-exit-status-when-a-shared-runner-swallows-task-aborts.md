---
module: timekeeping alerts specs
date: 2026-10-27
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: anchored
grounding_evidence: "In PR #218, spec/integration/timekeeping/alerts_live_spec.rb replaces a direct Rake invoke with run_timekeeping_alerts_task and adds expect(run.exit_status).to be_nil, with a comment saying the shared runner turns an abort into an exit status. spec/support/timekeeping/alerts_task_helpers.rb documents that exit_status is nil when the task finished without calling exit or abort."
audience: both
related_components:
  - spec/support/timekeeping/alerts_task_helpers.rb
  - spec/integration/timekeeping/alerts_live_spec.rb
tags:
  - rake-task-specs
  - system-exit
  - shared-test-helpers
  - exit-status
applies_when:
  - A spec stops invoking the timekeeping:alerts Rake task itself and calls run_timekeeping_alerts_task instead
  - A test helper rescues SystemExit and returns the status instead of letting it propagate
---

# Assert a nil exit status when a shared runner swallows task aborts

## Context

The `timekeeping:alerts` task calls `abort` when its metrics read fails. That raises `SystemExit`.

A spec that invokes the task directly with `Rake::Task[...].invoke` does not rescue that exception. So an abort fails the example, even when no assertion checks for it. The old live spec, `spec/integration/timekeeping/alerts_live_spec.rb`, relied on this without saying so.

The shared runner `run_timekeeping_alerts_task` in `spec/support/timekeeping/alerts_task_helpers.rb` rescues `SystemExit`. It returns the status as `exit_status`, which is `nil` when the task did not call `exit` or `abort`. The runner does this so specs can assert on failing runs.

The catch is that a caller moved onto this runner loses its implicit failure. If the task aborts, the caller gets back the output of a failed run. Assertions such as "no alert line for company X" can then pass on that partial output.

## Solution

When you move a spec from a direct invoke to the shared runner, list every place where an abort used to fail the example. Each of those places now needs an explicit check on `exit_status`.

If the spec only reads output, keep a thin wrapper that checks the status before it returns stdout. The live spec does this:

```ruby
# The shared runner turns an abort into an exit status, so a failed live run
# is checked here; otherwise the example would read the output of a failed run.
def run_alerts_task(now: nil)
  run = run_timekeeping_alerts_task(base_url: @timekeeping.base_url, token: @timekeeping.service_token, now:)
  expect(run.exit_status).to be_nil, "timekeeping:alerts exited #{run.exit_status}: #{run.stderr}"
  run.stdout
end
```

The failure message includes stderr, so a failed run says why it failed. Otherwise you only see a later assertion that does not match.

Some task spec examples that expect a clean run assert `expect(run.exit_status).to be_nil` (for example the reference_unavailable_rate and financial snapshot money examples); others, such as the entry_write_p95_latency and outbox_lag examples, do not, and so carry the same gap. Examples that expect an abort assert `not_to be_nil` and `not_to eq(0)`.

## Why it matters

A review that compares old and new examples line by line finds every `expect` unchanged. It still misses the lost check, because the old check was never an `expect`. It was an exception that nothing caught.

Absence assertions are where this does harm. An alert spec that checks a healthy company gets no alert line passes when the task aborts before it prints anything.

We have seen this only on the `timekeeping:alerts` runner. The same reasoning applies to any helper that turns an exception into a return value, but this change shows it only for this runner.

## Evidence

- PR #218, `spec/integration/timekeeping/alerts_live_spec.rb`: the old `run_alerts_task` called `Rake::Task["timekeeping:alerts"].invoke` with no rescue. The new wrapper calls `run_timekeeping_alerts_task` and adds `expect(run.exit_status).to be_nil` with the comment quoted above.
- PR #218, `spec/support/timekeeping/alerts_task_helpers.rb`: the comment on `TimekeepingAlertsTaskRun` says `exit_status is nil when the task finished without calling exit or abort`. The helper comments say the task aborts with `SystemExit` on a failed metrics read.
- PR #218, `spec/tasks/timekeeping_alerts_spec.rb`: the example "shared runner given now: puts the real clock back after a run that aborts on a failed metrics read" stubs a 500 response. It then shows that the runner returns a non-nil, non-zero `exit_status` and does not raise.
