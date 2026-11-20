---
module: Timekeeping queue ledger
date: 2026-11-20
problem_type: convention
component: testing_framework
severity: low
audience: both
related_components:
  - parallel_tests
  - RSpec
tags:
  - test-isolation
  - tmpdir
  - queue-ledger
  - path-assertions
applies_when:
  - A spec redirects a file into a Dir.mktmpdir directory and asserts it no longer hits a real per-process file
  - Writing a negative path assertion against Rails.root or the checkout
---

# Compare a private temp path to the exact worker path, not to the repository prefix

## Context

Some specs move a file that real workers own, such as `tmp/timekeeping-integration/queue_ledger.N.json`, into a private `Dir.mktmpdir` directory. They then assert that the new path is not the worker's path. A tempting way to write that is "the path does not start with `Rails.root`".

That check is wrong. `Dir.mktmpdir` creates its directory under `TMPDIR`. A developer or a CI job can set `TMPDIR` to a directory inside the checkout, for example `TMPDIR="$PWD/tmp"`. The private directory then starts with the repository path, and the prefix check fails even though no worker file is touched.

## Solution

Assert inequality against the exact file a worker would own, built the same way the code builds it:

```ruby
expect(path).to eq(File.join(dir, "tmp/timekeeping-integration", "queue_ledger.#{number}.json"))
expect(path).not_to eq(Rails.root.join("tmp/timekeeping-integration/queue_ledger.#{number}.json").to_s)
```

Pair it with a positive check that the path sits under the private directory (`start_with("#{dir}/")` or an exact `eq`). The positive check proves the redirect happened. The exact negative check proves the one file that matters was avoided. A check against the whole checkout adds nothing beyond these two, and it makes the spec depend on where the machine keeps temporary files.

## Why it matters

The isolation requirement is about specific files: worker files must never be written or deleted. Where the temp directory lives is not part of that requirement. A prefix check makes the spec stricter than the requirement, so it fails on machines with an in-repo `TMPDIR`. That is a false alarm, and someone may "fix" it by weakening the isolation itself.

## Evidence

- PR #432, `spec/meta/timekeeping_queue_ledger_spec.rb`: the examples "ledger_path puts a numbered default ledger file under TIMEKEEPING_QUEUE_LEDGER_ROOT instead of Rails.root" and "a private ledger root keeps the per-process number and never resolves to a worker path under Rails.root" assert `not_to eq(Rails.root.join("tmp/timekeeping-integration/queue_ledger....json").to_s)` against the exact worker file. They do not reject the whole checkout prefix.
- PR #432 review: an earlier version of that example used a checkout-prefix assertion. Running it with `TMPDIR="$PWD/tmp"` gave 1 failure: the path under `/workspace/checkout/tmp/queue-ledger-root...` was expected not to start with `/workspace/checkout`. After the switch to exact-path comparisons, the same command ran both examples with 0 failures.
