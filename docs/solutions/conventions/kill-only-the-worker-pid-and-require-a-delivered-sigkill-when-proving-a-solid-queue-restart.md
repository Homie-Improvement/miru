---
module: spec/support/timekeeping
date: 2026-11-24
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - solid_queue
  - timekeeping_relay
tags:
  - solid-queue
  - worker-restart
  - sigkill
  - live-specs
applies_when:
  - A live spec must prove recovery after a Solid Queue worker is killed and replaced
  - A helper reads worker pids from solid_queue_processes
---

# Kill only the worker pid, and require a delivered SIGKILL, when proving a Solid Queue restart

## Context

Some failure cases need a worker that dies abruptly and comes back as a new process. The Solid Queue supervisor starts a new worker when its forked worker dies. A test can force this by sending SIGKILL to the worker. Four traps make a naive helper wrong:

- The demo supervisor in `lib/timekeeping_demo/supervisor.rb` makes each of its direct children a process group leader. A kill sent to the group (`-pid`) ends the Solid Queue supervisor too, and the demo supervisor then stops every app.
- A killed worker's row in `solid_queue_processes` can stay after the process is gone. A row is not proof of a live worker.
- The monolith and Timekeeping both run a worker on a queue named `timekeeping_relay`, each registered in its own database.
- A worker can exit on its own before the signal arrives. `Process.kill` then raises `Errno::ESRCH`. If the helper ignores that and polls on, a normal replacement looks like recovery from a kill that never happened.

## Solution

Use one helper, `section_9_3_restart_queue_worker!(queue:, database:)`:

- Read Worker rows from the named database only (`:monolith` or `:timekeeping`), and keep rows whose `metadata["queues"]` include the queue.
- Count a row as live only while `Process.kill(0, pid)` succeeds (treat `EPERM` as alive).
- Refuse to act unless exactly one live worker serves the queue.
- Send `Process.kill(:KILL, pid)` to that positive pid only.
- Turn `Errno::ESRCH` from that kill into a `WorkerRestartFailed` error. Never poll past it.
- Poll with a fixed deadline (`WORKER_RESTART_SECONDS = 60`) until the killed pid is gone and a live row with another pid serves the queue. Return both pids, and lift any hold only after that.

## Why it matters

The acceptance rule is a killed worker replaced by a new one, not merely a changed pid. Each trap above lets the example pass while proving something else, or crashes the runtime for every later example. A dead row or an undelivered kill gives a green restart that tested no abrupt termination.

## Evidence

PR #617 adds `section_9_3_restart_queue_worker!`, `section_9_3_kill_worker`, `section_9_3_process_alive?`, `section_9_3_live_worker_pids` and the `WORKER_ROW_READERS` map in `spec/support/timekeeping/section_9_3_live.rb`. The helper's comment states the group-leader reason for killing only the pid, and the map's comment states that both apps run a `timekeeping_relay` worker. A review finding on this pull request showed the first version rescued `Errno::ESRCH` and accepted the replacement. The fix raises `WorkerRestartFailed` instead. The author's probe, which stubs the kill to raise `Errno::ESRCH` and then reports a new live pid, now raises "worker 100001 ended before SIGKILL reached it, so no kill was delivered". Both restart examples in `spec/integration/timekeeping/section_9_3_spec.rb` call the helper with an explicit `database:`.
