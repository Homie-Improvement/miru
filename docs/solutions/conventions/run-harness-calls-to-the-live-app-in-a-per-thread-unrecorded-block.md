---
module: spec/support/timekeeping
date: 2026-11-23
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - forwarded_timekeeping_request_log
  - webmock
tags:
  - live-regression
  - request-log
  - thread-local
  - webmock
applies_when:
  - A spec helper sends its own requests to the live Timekeeping app while ForwardedTimekeepingRequestLog is recording
  - Adding a pause or suppress switch to a shared recorder in spec support
---

# Run harness calls to the live app in a per-thread unrecorded block

## Context

`ForwardedTimekeepingRequestLog` records every request that reaches the live Timekeeping app's host and port, whatever the path. Specs then check exact lists, such as `forwarded_create_requests`, to prove what the monolith forwarded. When the harness also calls the live app itself, for example the `/internal/v1/handoff/drain` POST that delivers snapshots, those calls would show up in the exact lists and break the counts.

## Solution

- Wrap harness-owned calls in `ForwardedTimekeepingRequestLog.unrecorded { ... }`. It returns the block's value, and `record` returns early while it is active. Do not add a path filter to `record`, because the log's rule is that no path is left out.
- Store the pause flag in `Thread.current` (`PAUSED_KEY`), not in a module-level variable. Save the previous value before the block and restore it in `ensure`.
- Restore in `ensure` so that a drain that raises does not leave recording off for later examples.

WebMock records a request on the thread that sent it, so a per-thread flag leaves out only what this thread sends inside the block.

## Why it matters

With one shared flag, two overlapping blocks on different threads restore each other's saved values. If they finish in entry order, the second block puts back `true` after both have returned. Recording then stays off, later forwarded creates go missing, and exact-list checks pass or fail for the wrong reason. A reviewer's overlap script showed this. It printed `true` before the fix and `nil` after it.

## Evidence

- PR #577 adds `unrecorded` and `PAUSED_KEY` to `spec/support/timekeeping/forwarded_timekeeping_helpers.rb`. `record` returns early when `Thread.current[PAUSED_KEY]` is set.
- `spec/support/timekeeping/projection_relay.rb` in the same PR runs the live drain inside `ForwardedTimekeepingRequestLog.unrecorded`.
- `spec/contracts/timekeeping/forwarded_timekeeping_helpers_spec.rb` checks that a drain inside the block is not counted as a forwarded create, and that recording resumes after the block raises `IOError`.
- In the round 3 code review, the shared flag left recording on `true` after two overlapping threads. With the per-thread flag, the same script printed `paused after both blocks: nil`.
