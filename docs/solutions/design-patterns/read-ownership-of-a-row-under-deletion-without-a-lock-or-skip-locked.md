---
module: timekeeping
date: 2026-11-21
problem_type: design_pattern
component: service_layer
severity: high
audience: both
related_components:
  - database
  - api_layer
tags:
  - row-lock
  - skip-locked
  - ownership
  - agent-destroy
  - detach-entries
applies_when:
  - A decision must know whether a row belongs to a company while another transaction deletes that row
  - An existing list or fact is read with SKIP LOCKED or a share lock
---

# Read ownership of a row under deletion without a lock or SKIP LOCKED

## Context

Agent destroy locks the agent row and then calls detach-entries. Detach-entries must decide whether the requesting company owns that agent. If it does, the detach stores its receipt. That receipt is the marker that refuses a later entry write naming the agent being deleted.

The monolith's reference endpoint already returned an `agents` list. That list leaves out an agent whose row is locked. So the one agent this decision is about, the one being deleted, looks exactly like another company's agent. Reusing `agents` would drop the marker for the real delete.

## Solution

Answer ownership with a separate, plain read that takes no lock and does not skip locked rows. In `app/services/timekeeping/reference_facts.rb`, `owned_agent_ids` runs:

```ruby
company.agents.where(id: requested_agent_ids).order(:id).pluck(:id)
```

In the in-process store, `app/services/timekeeping/local_owner/service_commands.rb` uses `Agent.where(company_id:, id: agent_id).exists?`. A plain read does not wait on another transaction's `FOR UPDATE`, and it still sees the locked row. So it neither blocks the destroy nor misses the agent.

Keep the locked-row-skipping list for what it was built for. Add the plain read as its own fact, and write in the contract which of the two sees locked rows.

## Why it matters

If the check waits on the lock, it waits on the transaction that called it, and the destroy stalls. If the check skips locked rows, an own agent with no entries is treated as foreign. Then no marker is stored, and a create that timed out earlier can still write an entry naming a deleted agent. Both failures appear only when the lock is held, which ordinary tests do not arrange.

To test it, hold the row `FOR UPDATE` in another thread, call the read under a short timeout, and assert the row is listed. Stop the holder thread with the shared cleanup helper, not a bare bounded join.

## Evidence

- PR #570 adds `owned_agent_ids` in `app/services/timekeeping/reference_facts.rb` as a plain read. Its comment says it lists an agent whose destroy holds its row lock, unlike `agents`.
- `contracts/timekeeping/reference.yml` adds the `owned_agents` rule: read without a row lock, so the agent being deleted is still listed while `agents` leaves it out.
- `spec/services/timekeeping/reference_facts_spec.rb` holds the agent row `FOR UPDATE` in another thread, calls the facts inside `Timeout.timeout(5)`, and expects `owned_agent_ids` to include the locked agent while `agents` does not.
- `spec/services/timekeeping/local_owner_service_commands_spec.rb` detaches an own agent inside `own_agent.with_lock` and expects `agent_detached?` to be true.
- `docs/architecture/timekeeping-soa.md` section 3.4 records why `agents` cannot answer this question.
