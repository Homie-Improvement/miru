---
module: Timekeeping proof harness
date: 2026-11-19
problem_type: convention
component: testing_framework
severity: high
audience: both
related_components:
  - TimekeepingQueueLedger
  - spec/fixtures/timekeeping_harness
tags:
  - subprocess
  - probe
  - queue-ledger
  - before-suite
applies_when:
  - Adding a spec that runs bundle exec rspec in a child process through Open3 or similar
  - Adding a new probe fixture under spec/fixtures/timekeeping_harness
---

# Give every RSpec subprocess its own queue ledger path

## Context

The queue ledger keeps its findings in a JSON file, by default `tmp/timekeeping-integration/queue_ledger.json`. The file sits outside the database because every reset empties the Solid Queue tables. After a reset, the file is the only record of a forbidden execution.

`spec/support/timekeeping/queue_ledger.rb` deletes that file in a before(:suite) hook, so each run starts clean. A child `bundle exec rspec` process loads the same support files through `rails_helper`. If the child inherits the parent's path, its suite start deletes the parent's ledger in the middle of the parent's run.

## Solution

Every spec that starts an RSpec subprocess sets `TimekeepingQueueLedger::PATH_KEY` (`TIMEKEEPING_QUEUE_LEDGER_PATH`) to a file in its own temporary directory:

```ruby
Dir.mktmpdir("owner-state-probe-ledger") do |dir|
  env = { "TIMEKEEPING_OWNER_STATE" => owner_state,
          TimekeepingQueueLedger::PATH_KEY => File.join(dir, "queue_ledger.json") }
  Open3.capture3(env, "bundle", "exec", "rspec", probe, chdir: Rails.root.to_s)
end
```

This applies to runners that have nothing to do with the ledger, such as the owner-state probes and the live-skip check. To prove a runner is isolated, write a violation into a parent ledger file, point the parent's environment at it, run the probe, and assert the file is byte-for-byte unchanged.

## Why it matters

A runner without its own path still passes its own test. The damage happens elsewhere: the parent's recorded violation disappears, and the final verdict passes a run that should fail.

The same gap remains under `bin/parallel_test`. The processes share `tmp/`, and the pull request defers that case as follow-up work.

## Evidence

- PR #393, `spec/support/timekeeping/queue_ledger.rb`: the before(:suite) hook calls `FileUtils.rm_f(TimekeepingQueueLedger.session.path)`, and `ledger_path` reads `PATH_KEY`.
- PR #393, `spec/meta/timekeeping_owner_state_spec.rb`: `run_probe` and both seeded-probe runs now pass a private `PATH_KEY`. The new example "an owner state probe leaves the parent's inherited ledger file byte for byte unchanged" checks this.
- PR #393, `spec/lib/timekeeping_demo/integrated_runtime_skip_spec.rb`: the child run gets its own ledger file.
- PR #393, `spec/meta/timekeeping_queue_ledger_spec.rb`: the example "a clean probe run leaves the parent's inherited ledger file byte for byte unchanged" checks the queue-ledger probe in the same way.
