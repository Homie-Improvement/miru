---
module: timekeeping
date: 2026-10-26
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: anchored
grounding_evidence: "timekeeping/spec/jobs/relay_job_worker_spec.rb in PR #111 waits on finished_relay_run_since(inserted_at), a solid_queue_jobs query for a finished RelayJob created after the insert, before expecting posted_positions to be empty; the PR body reports that moving the worker to another queue made this wait time out."
audience: both
related_components:
  - background_job
  - solid_queue
tags:
  - negative-assertion
  - polling
  - recurring-job
  - pause-resume
applies_when:
  - A spec asserts that a background worker did not act during some window
  - A recurring job runs on a schedule in another process
---

# Wait for a finished run before asserting that nothing happened

## Context

The Timekeeping relay can be paused by a request. A spec must show that a paused worker sends nothing. The easy version sleeps a few seconds and then checks that the fake endpoint got no request. That check passes for the wrong reason when the worker never ran: a config that never schedules `RelayJob`, or a worker on the wrong queue, also delivers nothing.

## Solution

Before asserting the absence of an effect, wait for positive proof that the actor ran inside the window. In `timekeeping/spec/jobs/relay_job_worker_spec.rb`:

1. Record a database timestamp right after the setup step: `inserted_at = connection.select_value("SELECT clock_timestamp()")`.
2. Poll until `solid_queue_jobs` holds a `RelayJob` row with `created_at > inserted_at` and `finished_at IS NOT NULL`.
3. Only then expect no posted positions, a nil `sent_at` and no projected entry.

Use the same rule after the positive step. Once the row is delivered, wait for one more finished run, then check the row was posted exactly once and `sent_at` did not change.

Every wait is a deadline poll on the monotonic clock, never a fixed sleep. A timeout names what was missing and prints the child's captured output.

## Why it matters

The wait turns one assertion into two. A worker that ignores the pause delivers before the wait ends, so the empty check fails. A schedule that never runs the job makes the wait time out. A plain sleep catches neither failure and also makes the spec slow and timing-dependent. The PR body reports both breakages were tried: moving the worker to another queue made the wait time out, and forcing `relay_paused?` to false made the no-delivery check fail.

This depends on the queue keeping finished job rows. If finished jobs are deleted, the query has nothing to find, so pick another trace of a completed run.

## Evidence

- PR #111, head commit 5e719eb4fe5f8bc136ea63f752abf6809dab37e9, file `timekeeping/spec/jobs/relay_job_worker_spec.rb`.
- The `finished_relay_run_since` lambda queries `solid_queue_jobs` for `class_name = 'RelayJob' AND created_at > ? AND finished_at IS NOT NULL`.
- The paused phase calls `wait_for.call("a RelayJob run finished while paused", 25)` before the three empty-state expectations. The comment there says a worker that ignored the pause would have delivered by then, and a config that never schedules `RelayJob` fails the wait.
- After resume, the spec waits for `"a RelayJob run finished after delivery"` and then expects `posted_positions` to equal `[entry_id]` and `sent_at` to equal `first_sent_at`.
- The `wait_for` lambda uses `Process::CLOCK_MONOTONIC` and raises with the worker's log contents on timeout.
- The PR #111 body's test plan reports the two temporary breakages and their failures.
