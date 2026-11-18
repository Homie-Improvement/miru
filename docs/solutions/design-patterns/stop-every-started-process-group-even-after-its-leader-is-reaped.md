---
module: timekeeping_demo
date: 2026-11-18
problem_type: design_pattern
component: development_workflow
severity: medium
audience: both
related_components:
  - lib/timekeeping_demo/supervisor.rb
tags:
  - process-groups
  - shutdown
  - signals
  - solid-queue
applies_when:
  - A Ruby launcher spawns child processes that fork their own workers
  - A launcher runs setup commands before installing its stop handling
---

# Stop every started process group, even after its leader is reaped

## Context

`TimekeepingDemo::Supervisor` spawns each demo process with `pgroup: true`, so each one leads a process group whose id is its pid. Stopping sends `TERM`, then `KILL`, to `-group`. Solid Queue supervisors fork worker processes into that group.

The first version kept one map of running pids. When a leader exited, the wait loop reaped it and deleted it from the map, and shutdown then skipped its group. The workers it had forked kept running and claiming jobs with the old run's credentials. The same gap hit `db:prepare`: it ran before signal handling was set up and was not tracked, so a `TERM` to the launcher left it running.

## Solution

- Keep two lists. `groups` holds every group id ever started and is never shrunk. `running` holds leader pids not yet reaped and is used only for reaping.
- In `stop`, signal every entry in `groups`, poll `Process.kill(0, -group)` until all are gone or `STOP_GRACE_SECONDS` passes, then `KILL` every group. Reap leaders separately so they do not linger as zombies inside their group.
- Run setup children (`db:prepare`) in their own group too. Wrap the wait in `begin ... ensure` and stop that group when no exit status was received, which happens when a signal interrupts the wait.
- The trap handler only writes a byte to a pipe; the main loop reads it, because a trap handler may not take locks.

## Why it matters

A reaped leader says nothing about its group. Tests that watch only the leader report a clean stop while orphaned workers keep processing a queue. Here the risk was workers from a stopped demo running seeded integration jobs.

## Evidence

- PR #354, `lib/timekeeping_demo/supervisor.rb`: `run` keeps `groups` apart from `running`, with a comment that a leader can exit while its forked processes keep running; `stop` signals all `groups`; `prepare` stops the `db:prepare` pid in `ensure` when no status was received.
- PR #354, `spec/lib/timekeeping_demo/supervisor_spec.rb`: "stops a process its leader forked even after that leader has exited", "stops every process group, including a child that ignores TERM, when the launcher receives TERM", and "stops a running db:prepare when the launcher receives TERM during preparation".
- The author's recorded check in PR #354: with the old stop logic the TERM-ignoring child was still running (state `S`); with the new logic it was gone.
