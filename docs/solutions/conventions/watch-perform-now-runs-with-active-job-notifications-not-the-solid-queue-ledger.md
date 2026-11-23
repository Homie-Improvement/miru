---
module: spec/support/timekeeping
date: 2026-11-23
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - spec/integration/timekeeping
  - active_job
tags:
  - queue-ledger
  - perform-now
  - active-support-notifications
  - solid-queue
applies_when:
  - A spec runs a job with perform_now while relying on the teardown queue ledger
  - A job may run other jobs inline from its perform method
---

# Watch perform_now runs with Active Job notifications, not the Solid Queue ledger

## Context

The teardown queue ledger in `spec/support/timekeeping/queue_ledger.rb` fails the suite when a job from a non-dedicated queue ran. It finds those jobs by reading Solid Queue rows.

A job run with `perform_now` runs in the test process and writes no Solid Queue row. Any job it runs inline in turn writes none either. So an inline `Timekeeping::RelayJob.perform_now` in a live spec is invisible to the ledger, even when the example carries `:integrated_runtime` and the ledger is active.

## Solution

Wrap the inline run in `TimekeepingQueueLedger.inline_performs`. It subscribes to `perform_start.active_job` with `ActiveSupport::Notifications.subscribed` for the block only, and returns the queue name of every job that started, nested inline jobs included.

Judge the result with `TimekeepingQueueLedger.non_dedicated_queues(queues, database:)`. It reads `DEDICATED_QUEUES`, so the allowed list stays in one place, and it raises `KeyError` for an unknown database.

```ruby
relay_queues = TimekeepingQueueLedger.inline_performs { Timekeeping::RelayJob.perform_now }
expect(TimekeepingQueueLedger.non_dedicated_queues(relay_queues, database: "monolith")).to eq([])
```

Do not assert only on the outer job's queue or on adapter job arrays. A future `perform_now` of a default-queue job inside the relay's `perform` would pass both.

## Why it matters

An active ledger makes a spec look fully watched. Without this wrapper, an inline run can execute a job from any queue and the suite still passes. The block-scoped subscription also stops collecting when the block ends, so later jobs in the example are not counted.

## Evidence

- PR #585 adds `inline_performs` and `non_dedicated_queues` to `spec/support/timekeeping/queue_ledger.rb`. Its comment states that a `perform_now` job writes no Solid Queue row, so the collectors never see it.
- `spec/meta/timekeeping_queue_ledger_spec.rb` runs a `:default` job inline from inside a `:timekeeping_relay` job. `inline_performs` returns both queues, `non_dedicated_queues` reports `["default"]`, and a job run after the block is not collected.
- `spec/integration/timekeeping/late_replay_spec.rb` wraps its inline relay run this way, and its header comment explains why. That live example is skipped without `TIMEKEEPING_LIVE=1`, so its assertion did not run in this pull request.
