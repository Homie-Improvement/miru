---
module: timekeeping
date: 2026-11-24
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - spec/support/committed_data.rb
tags:
  - concurrency-specs
  - threads
  - teardown
  - committed-data
applies_when:
  - A race spec runs product calls in worker threads and joins them
  - Its ensure block moves from thread.join to stop_committed_data_threads or another helper that swallows worker errors
---

# Assert the worker join returns its thread before cleanup that drops worker errors

## Context

Race specs run each side of the race in a worker thread. An old teardown such as `[creator, destroyer].compact.each { |thread| thread.join(5) }` re-raises any error a worker ended with. So a destroy that failed still failed the example, even when the body never checked it.

Some cleanup helpers drop worker errors on purpose, such as `stop_committed_data_threads`. This keeps teardown noise out of the result. Switching to one of them removes that hidden check. If the body's `join(10)` times out or its result is ignored, a failed worker no longer fails the example.

## Solution

- Before joining any worker, read the lock-wait facts and assert them. Then a missing lock fails on an assertion that names the lock. Otherwise it fails through the error a worker raises once it runs unblocked.
- In the body, assert the join itself: `expect(destroyer.join(10)).to be(destroyer), "the agent destroy did not finish within 10 seconds"`. `Thread#join` re-raises the worker's error. It returns the thread when the worker finished and `nil` when the worker is still running. This assertion catches both a failed worker and a stalled one.
- Only after that, let `ensure` call the cleanup that drops worker errors.

## Why it matters

A cleanup refactor that looks harmless can turn a red example green. The example then passes while the worker it depends on crashed. Checking lock waits before the join keeps a lock-removal run failing on a named assertion. A failure that is only an error does not count as proof that the lock matters.

## Evidence

In PR #618, `spec/services/timekeeping/gateway_agent_race_spec.rb` replaces the per-thread `join(5)` teardown with `stop_committed_data_threads(creator, destroyer)`. It moves `expect(blocked)` before `holder.join` and `creator.join`, and adds `expect(destroyer.join(10)).to be(destroyer)` with a comment explaining why. In review, a comparison run first showed the gap: with the old teardown, a raising destroy worker failed the example. With `stop_committed_data_threads`, it did not. The author then checked `Thread#join`. It re-raised a worker's error, returned the thread for a finished worker, and returned `nil` for one still running. On the restored tree, `gateway_agent_race_spec.rb` passed. The removal record in `docs/solutions/conventions/identify-the-lock-a-session-waits-on-not-only-that-it-is-blocked.md` notes the earlier error-only reds and the fix.
