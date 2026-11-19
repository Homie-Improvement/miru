---
module: timekeeping_demo
date: 2026-11-19
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - TimekeepingDemo::CLI
  - TimekeepingDemo::Supervisor
tags:
  - rspec
  - instance-double
  - test-doubles
  - credentials
  - spec-refactor
applies_when:
  - Replacing a method_missing or catch-all recording double with an instance_double
  - The code under test passes the same data to more than one collaborator method
  - Merging or tidying specs that guard a secret or credential boundary
---

# Record every call a replaced recording double used to capture

## Context

The CLI credential specs in `spec/lib/timekeeping_demo/cli_spec.rb` used a hand-rolled supervisor double, `caller_credentials_supervisor_class`. Its `method_missing` caught every call and kept each `TimekeepingDemo::ProcessSpec` argument. So it recorded the specs passed to `prepare` and the specs passed to `run`, without naming either.

When the near-copy examples were merged, that class was replaced with `instance_double(TimekeepingDemo::Supervisor)`. The first version only recorded `run`, and `allow(supervisor).to receive(:prepare)` dropped prepare's arguments. Every kept assertion still passed. But `prepare` starts real child processes with each spec's env, so it is a credential boundary too. A change that gave Timekeeping the private key only during `db:prepare` would have passed both merged credential examples.

## Solution

Before you delete a catch-all double, list every method it captured that receives the data your assertions guard. Record each one in the new double. Then either assert on every list, or assert that the lists match the one you check in detail.

The fix in `cli_spec.rb`:

```ruby
def caller_credentials_recording_supervisor(started, prepared)
  supervisor = instance_double(TimekeepingDemo::Supervisor)
  allow(supervisor).to receive(:prepare) { |specs| prepared.concat(specs) }
  allow(supervisor).to receive(:run) { |specs, **| started.concat(specs) }
  supervisor
end
```

Both the complete-set and the partial/blank examples then assert `expect(prepared == started).to be(true)`. The comparison is a boolean on purpose: a failure prints `true`/`false`, never a key or token. The detailed per-app checks on `started` now cover preparation too.

## Why it matters

A catch-all double gives coverage that no line of the spec states. Removing it removes that coverage, and no test fails, because the code is still correct today. The gap only shows up when a later change leaks through the call nobody records. For secrets, that later change is a leak that ships without anything catching it.

## Evidence

- PR #392, `spec/lib/timekeeping_demo/cli_spec.rb`: the diff removes `caller_credentials_supervisor_class`, whose `method_missing` collected every `TimekeepingDemo::ProcessSpec` argument. It adds `caller_credentials_recording_supervisor(started, prepared)` and the `expect(prepared == started).to be(true)` checks in both merged credential examples. Its comment says prepare spawns real children with each spec's env.
- Review of PR #392 found that a preparation-only private-key leak passed the merged examples when only `run` was recorded. To check the fix, the author temporarily changed `supervisor.prepare(specs)` in `lib/timekeeping_demo/cli.rb` to add the private key to the Timekeeping specs. The result was 9 examples with 2 failures: both credential examples failed on the prepare-equals-run check. With the code restored, the run had 9 examples and 0 failures.
