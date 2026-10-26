---
module: spec/services/timekeeping
date: 2026-10-26
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: anchored
grounding_evidence: "In PR #140, spec/services/timekeeping/projection_consumer_spec.rb replaces `expect(flip.join(0.5)).to be_nil` with `blocked_by?(flip_pids.pop(timeout: 5), delivery_pids.pop(timeout: 5))` inside a begin/ensure that releases the paused delivery. Issue #137 explains why the join check could not tell a lock wait from a thread that had not sent its statement."
audience: both
related_components:
  - CommittedDataMode::Helpers
  - TimekeepingOwnership
tags:
  - concurrency-specs
  - postgres-locks
  - backend-pid
  - blocked-by
  - committed-transactions
applies_when:
  - A spec claims that one thread's statement waits on a row lock held by another, paused thread
  - A concurrency example asserts `thread.join(timeout)` is nil to show that a thread is blocked
---

# Prove a lock wait with `blocked_by?` on backend pids, not a join timeout

## Context

Some specs pause one thread while it holds a database lock. They then start a second thread whose statement should wait for that lock. A common way to check the wait is `expect(flip.join(0.5)).to be_nil`, which means the second thread did not finish in half a second.

That check cannot tell the difference between two cases:

- Postgres is holding the second thread at the lock.
- The second thread has not yet checked out a connection or sent its statement.

Both cases make the join return nil. So the example still passes if the lock it is meant to prove is removed or moves elsewhere. Issue #137 raised this for the ownership flip example in `spec/services/timekeeping/projection_consumer_spec.rb`, after the billing fence specs had already been fixed the same way.

## Solution

Ask Postgres directly. Each thread records its backend pid, which is the server process that serves its connection. Then the spec asserts that the waiting pid is blocked by the holding pid while the holder is still paused.

In this repository, the tools come from `CommittedDataMode::Helpers`:

- `committed_data_thread(pids_queue)` runs a block on its own connection and pushes that connection's backend pid onto the queue.
- `blocked_by?(waiter_pid, holder_pid)` reports whether Postgres shows the waiter blocked by the holder.

The shape used in PR #140:

```ruby
delivery_pids = Queue.new
flip_pids = Queue.new

delivery = rules_thread(delivery_pids, pause: true) { previous.call(91_009) }
paused.pop
flip = rules_thread(flip_pids) { TimekeepingOwnership.current.update!(handoff_step: nil) }

begin
  blocked = blocked_by?(flip_pids.pop(timeout: 5), delivery_pids.pop(timeout: 5))
ensure
  release << true
end

expect(blocked).to be(true), "the ownership flip never waited on the paused delivery's lock"
```

Three details matter:

1. Check before you release. The wait only exists while the holder is paused. After `release << true`, there is nothing left to observe.
2. Release in `ensure`. If a pid pop times out or `blocked_by?` raises, the paused thread must still be freed. Otherwise the example hangs and leaves a connection checked out.
3. Route a spec-local thread helper through `committed_data_thread` instead of a raw `Thread.new` with `connection_pool.with_connection`. Here `rules_thread` gained an optional `backend_pids` argument for this, and the context gained `include CommittedDataMode::Helpers`.

## Why it matters

A concurrency spec that passes for the wrong reason is worse than having no spec. It tells reviewers that a lock order is protected when nothing checks it. The `blocked_by?` check fails when the lock wait disappears. The join check does not. The cost is small: two queues and one helper call.

When you review a spec that says one thread "waits" for another, look for a join timeout used as the proof. Ask for backend pids and `blocked_by?` instead.

## Evidence

- PR #140, head commit 0e7f2b917a9279d668d0f0e134da9b3600910069, changes `spec/services/timekeeping/projection_consumer_spec.rb`. It removes `expect(flip.join(0.5)).to be_nil` and adds the `blocked_by?` check inside `begin ... ensure release << true end`.
- In the same file, `rules_thread` now calls `committed_data_thread(backend_pids)` instead of `Thread.new` with `ActiveRecord::Base.connection_pool.with_connection`. The `with committed transactions` context now includes `CommittedDataMode::Helpers`.
- Issue #137 states the defect: the join check "cannot tell a real database lock wait from a thread that has not yet sent its statement". It also notes that the billing fence specs had already moved to this pattern.
- The PR #140 description reports a fault test. Swapping the two pids made the flip example fail with "the ownership flip never waited on the paused delivery's lock", so the new assertion can fail.
