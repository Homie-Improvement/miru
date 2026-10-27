---
module: spec/services/invoices
date: 2026-10-27
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: anchored
grounding_evidence: The after hook in spec/services/invoices/prepared_reservations_concurrency_spec.rb runs `thread.kill unless thread.join(5)`, then `thread.join`, with `rescue StandardError`; the author's recorded check showed the old join-only loop returned with a live worker and the new loop stopped it, and a killed writer's open transaction left 0 rows.
audience: both
related_components:
  - database
tags:
  - committed-data
  - concurrency
  - threads
  - teardown
  - rspec
applies_when:
  - A spec runs writers on their own database connections in threads and relies on committed-data cleanup after each example
  - A teardown joins worker threads with a timeout
---

# Kill writer threads left alive after a bounded join before committed-data cleanup

## Context

Committed-data specs run real writers on separate connections in threads. After each example, the committed-data reset deletes rows from the tables. If a writer thread is still running, it may still hold an open transaction and its row locks.

`Thread#join(5)` does not stop a thread. On timeout it just returns `nil`. A teardown that only calls `join(5)` and moves on can hand control to the cleanup while a writer is still inside its transaction. The cleanup then deletes rows under a live transaction, or waits on its locks.

## Solution

In the `after` hook, release the paused writer, then for each thread:

1. Join with a bound.
2. If the join timed out, kill the thread. Killing it ends its transaction with a rollback and returns its connection.
3. Join again with no bound, so the hook only returns once the thread has stopped.
4. Rescue `StandardError` around the joins. `join` re-raises the thread's own error; the thread has stopped by then, and the example's assertions already report the failure.

```ruby
after do
  release.push(true)
  [@holder, @waiter].compact.each do |thread|
    thread.kill unless thread.join(5)
    thread.join
  rescue StandardError
    nil
  end
end
```

Declare this hook in the spec so it runs before the committed-data cleanup.

## Why it matters

A join-only teardown passes every time the writers finish quickly. It fails only when a writer is slow or stuck, which is exactly when a race spec is already misbehaving. The result is then a hang or leaked rows in a later, unrelated example, far from the cause. Killing and re-joining makes "the hook returned" mean "every writer has stopped and rolled back".

## Evidence

- PR #230 adds the hook above to `spec/services/invoices/prepared_reservations_concurrency_spec.rb`. Its comment says a writer still running after the bounded join is killed, which rolls back its transaction, so the cleanup never deletes rows under a live transaction.
- A review finding on this pull request pointed out that the earlier hook discarded the `join(5)` result and did not stop the worker. A reproduction script with a delayed worker printed "teardown returned with a live worker" and exited 1 against the old loop.
- With the new kill-then-join loop, the same reproduction printed "worker stopped" and exited 0.
- A second recorded check killed a thread that had inserted into a probe table inside an open transaction. Afterwards the thread was not alive and the table held 0 rows, so the kill rolled the write back.
