---
module: timekeeping
date: 2026-11-24
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - background_job
tags:
  - rspec
  - around-hook
  - skip
  - pending
  - queue-ledger
applies_when:
  - You write an RSpec around hook that checks something after example.run and raises when the check fails
  - The examples under the hook can call skip or pending after doing the work the hook checks
---

# Clear the pending mark before an around hook fails a skipped example

## Context

Some RSpec hooks wrap each example, record what it did, and fail it afterwards if it did something forbidden. In this repository, the `:inline_jobs_on_dedicated_queues` hook in `spec/support/timekeeping/queue_ledger.rb` records the queues of jobs run with `perform_now`. It fails the example if any of those queues is not dedicated on the monolith. Jobs run that way write no Solid Queue row, so the teardown ledger never sees them, and this hook is the only check on them.

Two cases break the obvious version of such a hook:

- The example already failed on its own. If the hook raises anyway, its message can take the place of the error the reader needs to see.
- The example ran the forbidden job and then called `skip`. It is tempting to leave skipped examples alone. But the work happened before the skip, and no other check will see it.

A plain `raise` does not fix the second case. `skip` marks the example pending, and RSpec counts any error raised in a pending example as an expected failure. The run stays green.

## Solution

In the hook, check the example's own error first. Then clear the pending state before raising:

```ruby
config.around(:each, :inline_jobs_on_dedicated_queues) do |example|
  queues = TimekeepingQueueLedger.inline_performs { example.run }
  next if example.exception

  stray = TimekeepingQueueLedger.non_dedicated_queues(queues, database: "monolith").uniq
  next if stray.empty?

  example.metadata[:skip] = false
  example.metadata[:pending] = false
  example.execution_result.pending_message = nil
  raise RSpec::Expectations::ExpectationNotMetError,
        "jobs ran inline on non-dedicated monolith queues: #{stray.join(', ')}"
end
```

- `next if example.exception` keeps the example's own failure as the one RSpec reports.
- Skipped examples are still checked. The three assignments take away the pending state, so RSpec reports the raise as a real failure.

Test each case on its own. Run a tagged group in the same process with `RSpec::Core::ExampleGroup.describe(...).run(RSpec::Core::NullReporter)`, then delete it from `RSpec.world.example_groups`. Also run a child `rspec` process on a fixture whose name does not end in `_spec.rb`, so a normal suite run never loads it.

## Why it matters

A hook that ignores skipped examples has a gap anyone can step through: do the forbidden work, then skip. The suite stays green, and no other check reports it. A hook that raises without clearing the pending state looks right in review but still passes, so a test that runs the job and then skips is the only way to catch it. A hook that raises over an example's own error hides the real failure behind the hook's message. Apply all three rules to any new around hook that checks the example's effects.

## Evidence

- PR #602 adds the hook to `spec/support/timekeeping/queue_ledger.rb`. Its comment says RSpec files any error raised in a pending example as an expected failure, and that `skip` marks the example pending, so the hook clears the mark first.
- `spec/meta/timekeeping_queue_ledger_spec.rb` adds "the inline queue hook fails a tagged example that runs a default-queue job inline and then skips". It expects the inner group run to return `false`, with an exception message naming `default`. The same file adds "the inline queue hook keeps an example's own failure and fails a clean example that ran a default-queue job", which checks that the example's own message survives.
- `spec/fixtures/timekeeping_harness/inline_dedicated_queue_probe.rb` holds the `skip_after_default` scenario. The meta spec runs it in a child `rspec` process and expects a non-zero exit with `default` in the output.
- The PR body reports these specs passing, and the platform's reading of the checks at the head commit found no failed check.
