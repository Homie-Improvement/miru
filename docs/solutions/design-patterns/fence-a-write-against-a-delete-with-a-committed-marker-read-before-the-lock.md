---
module: timekeeping
date: 2026-11-14
problem_type: design_pattern
component: service_layer
severity: medium
audience: both
related_components:
  - database
  - testing_framework
tags:
  - advisory-lock
  - detach-marker
  - sequence-fence
  - race-condition
  - idempotency-receipt
applies_when:
  - A write must be refused when a delete or detach of the thing it names commits after the write began
  - The delete stores a receipt row while it holds a lock the write also takes
  - You are tempted to copy a fence read from pg_sequence_last_value
---

# Fence a write against a delete with a committed marker read before the lock, not a sequence fence

## Context

Local `detach_entries` clears `agent_id` on every entry of a company that names an agent. Its row locks cannot see an entry that does not exist yet. So a local create naming the agent could commit just after the detach and keep the reference. The fix makes the entry writer take the detach's per-agent advisory lock and refuse with `not_found` when a detach of that agent committed after the write began.

The hard part is deciding "after the write began". The timekeeping service does it with a fence: it reads `pg_sequence_last_value` and refuses on detach receipts with a higher id. That fence has a hole. A sequence hands out ids when a row is inserted, not when it commits. A detach that inserted its receipt before the fence read, but commits after it, has an id at or below the fence. The write treats it as an old detach and lands right after it.

## Solution

Use a marker built only from committed rows, read before any lock, and checked again after the lock:

1. At the very start of the write, before any lock, read the marker: the highest id of committed detach receipts for this company and agent, or 0.
2. Take the same lock the detach holds while it inserts and commits its receipt.
3. After the lock (and after replaying any stored receipt for this request), refuse when a detach receipt with an id above the marker exists.

In PR #287 this is `ServiceCommands.detach_marker` (`detach_receipts(...).maximum(:id) || 0`) and `ServiceCommands.agent_detached?(company_id, agent_id, after:)` (`where("id > ?", after).exists?`), called from `LocalOwner#write` around `ServiceCommands.lock_agent`.

Why it closes the hole: a detach that is in flight at the marker read holds the agent lock, and its receipt is not committed, so the marker does not count it. The write then waits on the lock, and once the detach commits, its receipt is visible with an id above the marker. Two detaches of one agent run one after the other on that lock, so the later one always gets a higher id than every committed one.

It also keeps the outcome a fence was meant to give: a detach that committed before the write began is at or below the marker. A later write for an agent that still exists is accepted, not refused forever.

The pattern needs two conditions. The delete must insert its receipt while it holds the lock the write takes. Deletes of the same key must take that lock too. If either fails, the marker check is not safe.

## Why it matters

A sequence fence looks equivalent and passes every test where the delete has either fully committed or not started when the write begins. Only one ordering tells the two apart: the delete has inserted its receipt but not committed. Copying the service's fence into a new owner would ship that hole silently. The committed marker also reads no cross-company sequence, so it shares nothing between tenants.

When you test this, force that ordering. Pause the delete after it inserts its receipt and before commit, start the write, prove with `blocked_by?` that it waits on the lock, then release the delete and expect the refusal.

## Evidence

- PR #287, `app/services/timekeeping/local_owner/service_commands.rb`: adds `self.detach_marker` (newest receipt id or 0), `self.agent_detached?(company_id, agent_id, after:)`, and `self.lock_agent`, with comments saying the write reads the marker before it takes the agent lock.
- PR #287, `app/services/timekeeping/local_owner.rb`: `write` reads `detach_marker` before `lock_receipt_key`, calls `ServiceCommands.lock_agent` before `admitted_generation`, and returns `Outcome.refusal(:not_found)` from `agent_detached?` only after receipt replay. The header step list states the same order.
- PR #287, `spec/services/timekeeping/local_owner_agent_race_spec.rb`: the AE4 example pauses the detach at `:receipt_written` (receipt inserted, not committed), proves the create waits with `blocked_by?`, and expects 404 `not_found` with no entry, audit, outbox or user receipt rows. Its comment notes that a fence read while the detach is paused would already count the receipt as old.
- The same spec's AE3 example and `spec/services/timekeeping/local_owner_service_commands_spec.rb` show an older committed detach does not refuse a later write, and that `agent_detached?` ignores a receipt at or below the marker.
- The PR body records this departure from the service's global sequence fence and why.
