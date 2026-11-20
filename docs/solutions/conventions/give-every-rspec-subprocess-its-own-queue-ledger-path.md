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

Under `bin/parallel_test` the processes share `tmp/`. That case is now handled by the default path, not by this convention. With no override, `ledger_path` adds the process's `TEST_ENV_NUMBER` to the default file name, so process N writes `queue_ledger.N.json`. The first process, whose number is empty, keeps `queue_ledger.json`. An explicit `PATH_KEY` is still used exactly as written, so a subprocess's private file is never renamed. `bin/parallel_test` refuses to start when `TIMEKEEPING_QUEUE_LEDGER_PATH` is set, because every process would inherit and share that one file. It also hands its workers the key set to an empty string, so a value in `.env` cannot fill it in.

A spec that must exercise the numbered default name, rather than an explicit file, sets `TIMEKEEPING_QUEUE_LEDGER_ROOT` (`TimekeepingQueueLedger::ROOT_KEY`) to its own `Dir.mktmpdir` directory instead. `ledger_path` then builds `<root>/tmp/timekeeping-integration/queue_ledger.N.json`, so the spec keeps the per-process naming without touching the files real workers own under `Rails.root`, whatever `-n` the run uses. The root must be an absolute path; a relative one raises `ArgumentError`. An explicit `PATH_KEY` still wins over a root. Pass the root to a child process explicitly, beside `PATH_KEY => ""`, because the child reads it from its own environment.

## Evidence

- PR #393, `spec/support/timekeeping/queue_ledger.rb`: the before(:suite) hook calls `FileUtils.rm_f(TimekeepingQueueLedger.session.path)`, and `ledger_path` reads `PATH_KEY`.
- PR #393, `spec/meta/timekeeping_owner_state_spec.rb`: `run_probe` and both seeded-probe runs now pass a private `PATH_KEY`. The new example "an owner state probe leaves the parent's inherited ledger file byte for byte unchanged" checks this.
- PR #393, `spec/lib/timekeeping_demo/integrated_runtime_skip_spec.rb`: the child run gets its own ledger file.
- PR #393, `spec/meta/timekeeping_queue_ledger_spec.rb`: the example "a clean probe run leaves the parent's inherited ledger file byte for byte unchanged" checks the queue-ledger probe in the same way.
