---
module: timekeeping
date: 2026-10-27
problem_type: design_pattern
component: service_layer
severity: high
evidence_grounding: anchored
grounding_evidence: "PR #223: timekeeping/app/services/timekeeping/entry_writer.rb names_detached_agent? takes ServiceCommands.lock_agent and checks agent_detached?(after: command.detach_fence); entry_command.rb reads the fence before the facts; app/services/timekeeping/reference_facts.rb uses FOR KEY SHARE SKIP LOCKED; timekeeping/spec/services/timekeeping/entry_writer_race_spec.rb covers all three orderings"
audience: both
related_components:
  - database
  - api_layer
tags:
  - concurrency
  - advisory-lock
  - timeout
  - agent-detach
  - fence
  - timekeeping
applies_when:
  - A monolith forwards a write over HTTP to a store that owns the data, while a concurrent delete of a referenced record must not be overtaken
  - A durable receipt is used as a 'this record was deleted' marker but the delete can still roll back on the caller's side
---

# Order a remote create against a delete in the owning store, and fence the delete marker

## Context

An agent create forwarded from the monolith to Timekeeping must never leave an entry naming a deleted agent. In the monolith, the gateway takes a share lock on the agent row (through `TimesheetEntry#validate_agent_exists`) and holds it through the forwarded call. An agent destroy that locks the row first wins, and one that waits detaches the new entry.

That lock protects only while the caller waits. If the HTTP call times out, the monolith transaction rolls back and the lock is released. The Timekeeping request can still be running. A destroy can then detach zero entries and commit, and Timekeeping can commit the entry afterwards. The checks in Timekeeping read agent facts before its transaction opened, so they still list the agent.

The first fix in PR #223 refused any create once a detach receipt for the agent existed. That closed the race but broke a different case. When the monolith destroy rolls back after the remote detach committed, for example because the reply was lost, the agent still exists, yet every later create for it answered 404.

## Solution

Order the two operations inside the owning store, and limit the marker to writes it can actually threaten:

1. **Take the same lock the delete takes.** `EntryWriter#names_detached_agent?` calls `ServiceCommands.lock_agent`, the advisory lock that detach-entries takes. It does this right after the receipt-key lock and before the admission read, in the same order the detach uses, so a handoff fence cannot leave the two waiting on each other.
2. **Read a fence before the facts.** `EntryCommand.build` reads `ServiceCommands.detach_fence` before it fetches reference facts. The fence is the last value of `service_idempotency_receipts_id_seq`. A detach that commits later gets a higher receipt id.
3. **Refuse only on a newer marker.** `ServiceCommands.agent_detached?(company_id, agent_id, after: command.detach_fence)` looks only for detach receipts with `id > fence`. Such a receipt means the facts this write relies on may be out of date, so the write answers `not_found`.
4. **Keep agents that are being deleted out of the facts.** `ReferenceFacts#agents` reads with `lock("FOR KEY SHARE SKIP LOCKED")`. An agent whose destroy holds its row lock is left out without waiting, so facts never list an agent while its deletion may still commit. Any facts that list the agent were therefore read before the deletion began, or after it rolled back. An older receipt then belongs to a deletion that failed, and it no longer refuses that agent's writes.

The result: a late create built before the detach is refused, a create that holds the lock first is detached by the waiting detach, and a create built after a rolled-back deletion succeeds.

## Why it matters

- A caller-side lock held across a network call is a guarantee only for callers that wait. Any design that depends on it needs a second ordering in the store that commits the write.
- An unfenced delete marker is a permanent refusal. Lost replies and rollbacks after a remote side effect are ordinary events, so the bug would hit real agents, and the marker gives no operator path back.
- Tests where every call succeeds pass with either broken design. Only the three forced orderings below tell them apart.

## Evidence

- PR #223, `timekeeping/app/services/timekeeping/entry_writer.rb`: `names_detached_agent?` takes the agent lock, then calls `agent_detached?` with `after: command.detach_fence`. It runs after `receipt_checked` and before `locked_generation`.
- PR #223, `timekeeping/app/services/timekeeping/service_commands.rb`: adds `lock_agent`, `detach_fence` (reads `pg_sequence_last_value` of the receipt sequence) and `agent_detached?`.
- PR #223, `timekeeping/app/services/timekeeping/entry_command.rb`: reads `detach_fence` before `reference_client.fetch` and carries it on the command.
- PR #223, `app/services/timekeeping/reference_facts.rb`: `agents` uses `FOR KEY SHARE SKIP LOCKED`. `spec/services/timekeeping/reference_facts_spec.rb` shows that an agent locked `FOR UPDATE` is left out, then listed again once the lock is released.
- PR #223, `timekeeping/spec/services/timekeeping/entry_writer_race_spec.rb` covers three cases:
  - A detach waits on a create holding the lock, proven with `pg_blocking_pids`, then detaches the committed entry.
  - A create held before the lock is refused after a detach commits.
  - A create built after a committed detach for a surviving agent is accepted, while one built before it stays refused.
- In review, a later round found that the unfenced receipt check refused a fresh create for a surviving agent with 404. With the fence in place, the author's check of that create returned 201.
