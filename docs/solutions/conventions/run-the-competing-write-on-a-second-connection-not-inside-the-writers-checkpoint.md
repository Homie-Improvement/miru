---
module: timekeeping
date: 2026-11-15
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - Timekeeping::LocalOwner
  - spec/services/timekeeping/local_owner_agent_race_spec.rb
tags:
  - race-test
  - advisory-lock
  - savepoint
  - checkpoint
  - committed-data
applies_when:
  - A spec wants to prove a write is fenced against another write that commits while it is in flight
  - A spec passes a checkpoint lambda that calls Timekeeping::LocalOwner.call (or another locking operation) from inside the write
---

# Run the competing write on a second connection, not inside the writer's checkpoint

## Context

`Timekeeping::LocalOwner` writes accept a `checkpoint:` lambda. It is called at named steps such as `:receipt_key_locked`, so a test can pause or act at that point. One easy way to stage a race is to call a second operation, for example a `detach_entries`, from inside that lambda. The write then sees a detach that committed "after it began".

Issue #292 explains why this is not a race. `LocalOwner` wraps the write in `transaction(requires_new: true)`. A call made from the checkpoint therefore runs as a savepoint (a nested step inside the same database transaction) on the same connection. Postgres advisory locks are reentrant for a session: the connection that holds one can take it again without waiting. So the nested detach never waits on the writer's lock, and nothing runs at the same time. The example only checks what happens when one connection runs the two operations one after the other.

## Solution

- Put race and fence tests in the two-connection race spec, `spec/services/timekeeping/local_owner_agent_race_spec.rb`. There the writer and the competing write each run in their own `committed_data_thread`. The writer pauses at the checkpoint with a `Queue`, the other thread commits, and then the writer is released.
- Use the checkpoint lambda only to pause and signal, never to run the competing operation.
- Before you delete a checkpoint-driven example, move every distinct check it held to an example that runs the real race. In this change those checks were the `not_found` body not containing `"agent-destroy"`, the refused update's row attributes staying unchanged, and the user-receipt counts.

## Why it matters

A same-connection example gives the expected refusal, so it looks like proof of the fence. It does not test the part that can break in a real race: two sessions competing for the lock and for the committed detach receipt. A reader who trusts it can remove or weaken the real race test, believing the rule is still covered. Duplicate examples like these also make one rule appear in several files, and no single test owns it.

## Evidence

- PR #294 deletes three describes from `spec/services/timekeeping/local_owner_spec.rb`: "entry write against a detach of its agent", "entry update against a detach of the agent it sets" and "detach markers stay within their company". Each one calls `described_class.call(operation: :detach_entries, ...)` from inside a `checkpoint` lambda when `step == :receipt_key_locked`. A deleted comment says the detach "commits ahead of the write on the same connection".
- In the same pull request, the replacement table example in `spec/services/timekeeping/local_owner_agent_race_spec.rb` runs the create in one `committed_data_thread`. The create pauses at `:receipt_key_locked` with `agent_race_pause`, and the detach runs in a separate `committed_data_thread`. That spec's paused update example gains `expect(entry.reload.attributes).to eq(attributes_before)`, which keeps the unchanged-row check that only a deleted checkpoint example held.
- The claim that the write runs in `transaction(requires_new: true)` and re-takes the same advisory lock comes from issue #292. `app/services/timekeeping/local_owner.rb` is not part of PR #294. To verify it, read `LocalOwner#attempt` there.
