---
module: timekeeping
date: 2026-11-14
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - Timekeeping::LocalOwner
tags:
  - rspec
  - folding-examples
  - test-sequencing
  - rollback
  - idempotency
applies_when:
  - Folding several examples into one example that runs a sequence of calls against shared fixtures
  - A folded example mixes injected-failure or refusal checks with calls that succeed and change rows
---

# Order failure checks before mutating successes when folding examples into one sequence

## Context

When separate examples are merged into one, each original example used to start from fresh fixtures. After the merge, they all share one set of rows. A call that succeeds part-way through the merged example changes those rows, so every check after it runs against a different input than the original example had. Nothing fails when this happens. The check just tests a case nobody meant to test.

This happened in `spec/services/timekeeping/local_owner_service_commands_spec.rb`, in the "service command rollback" example. A dropped copy contributed a later retry: after injected failures, a retry with the same key must run. In the first version of the fold, the mark_billed retry ran before the detach_entries failure checks. Those checks then received an entry that was already billed, so the case "detach_entries rolls back cleanly on an unbilled entry" was no longer tested. The stale-retry fold had the same risk. The generation bump (`ownership.update!`) has to run only after both commands have stored their receipts. Otherwise the 409 check tests a retry with no stored answer, which is a different input.

## Solution

- Put all failure and refusal steps for every command first. Put the calls that succeed and change state after them.
- At each failure check, assert the precondition the original example relied on, not only "unchanged from before". A comparison with the previous state still passes when the previous state was already wrong.
- Put steps that change global state, such as a generation bump, after every step that needs the earlier state. Add a comment that says why the step is placed there.

The kept rollback example now reads like this:

```ruby
# All failures run before any retry, so each command fails against the unbilled entry that
# still carries the agent.
keyed_params.each do |operation, params|
  %i[entry_written outbox_written].each do |step|
    # ... inject the failure, then:
    expect(entry.attributes.values_at("bill_status", "agent_id")).to eq(["unbilled", 77])
  end
end

# Nothing was stored, so the same key runs as a first attempt.
keyed_params.each do |operation, params| ... end
```

## Why it matters

Folding examples is meant to keep every distinct input and assertion. Step order is part of the input. Without an explicit precondition assertion, a reordered step drops a case with no failure and no diff hunk that looks wrong. When you review a fold, read each moved check and ask what state the steps before it leave behind. Do not only confirm that the check still exists.

## Evidence

- PR #285 changes `spec/services/timekeeping/local_owner_service_commands_spec.rb`. The "service command rollback" example runs every `entry_written` and `outbox_written` failure for both commands before any retry. Each failure check now asserts `["unbilled", 77]`. The comment says why the failures run first.
- In the same file, the "service command retries" example calls `ownership.update!(generation: ownership.generation + 1)` only after the `stored_params` loop has stored both receipts. Its comment says the bump happens after both receipts are stored.
- A code review on PR #285 found the earlier order, where the mark_billed retry ran before the detach_entries failure checks. The author fixed it by moving the retries after all failures. The focused spec then ran with 15 examples and 0 failures.
