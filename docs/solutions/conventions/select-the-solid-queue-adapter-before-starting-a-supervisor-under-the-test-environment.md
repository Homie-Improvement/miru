---
module: timekeeping_demo
date: 2026-11-18
problem_type: convention
component: background_job
severity: medium
audience: both
related_components:
  - bin/timekeeping-demo-queue
  - spec/timekeeping/runtime_queues_spec.rb
tags:
  - solid-queue
  - active-job
  - recurring-tasks
  - test-environment
applies_when:
  - A monolith process starts SolidQueue::Supervisor with RAILS_ENV=test
  - A live spec relies on recurring tasks reaching the queue tables
---

# Select the Solid Queue adapter before starting a supervisor under the test environment

## Context

The live spec `spec/timekeeping/runtime_queues_spec.rb` starts the demo runtime with `RAILS_ENV=test`. The monolith's test environment sets `config.active_job.queue_adapter = :test`. Solid Queue's dispatcher enqueues recurring tasks through Active Job, so under that setting `Timekeeping::RelayJob` and `RecoverInvoiceOperationIntentsJob` go to the in-memory test adapter. The supervisor and workers still start and register, but nothing scheduled ever reaches `solid_queue_jobs`.

The Timekeeping app does not have this problem: its own config selects `:solid_queue` with no test override.

## Solution

Start monolith queue supervisors through a small entry point, `bin/timekeeping-demo-queue CONFIG_PATH`, that loads `config/environment`, then sets `ActiveJob::Base.queue_adapter = :solid_queue`, then calls `SolidQueue::Supervisor.start(load_configuration_from: config_path)`. The forked dispatcher and workers inherit the adapter.

In the live spec, first wait (deadline polling) for a finished run of each recurring job created after start, in each database. Only then assert that no job outside the dedicated queues was finished, claimed or failed.

## Why it matters

Without the adapter switch the runtime is silently idle. A spec that only asserts "no forbidden job ran" passes on an idle runtime, so the queue-isolation proof would mean nothing. Waiting for positive runs first turns the adapter mistake into a visible failure.

## Evidence

- PR #354, `bin/timekeeping-demo-queue`: sets `ActiveJob::Base.queue_adapter = :solid_queue` before `SolidQueue::Supervisor.start`, with a comment that the test environment selects the `:test` adapter.
- PR #354, `spec/config/timekeeping_demo_queues_spec.rb`: asserts from the script source that the adapter line comes before the supervisor start.
- PR #354, `spec/timekeeping/runtime_queues_spec.rb`: waits for finished `Timekeeping::RelayJob`, `RecoverInvoiceOperationIntentsJob` and Timekeeping `RelayJob` runs before any negative assertion.
