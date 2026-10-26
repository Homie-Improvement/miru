---
module: timekeeping
date: 2026-10-26
problem_type: design_pattern
component: timekeeping_service
severity: high
evidence_grounding: anchored
grounding_evidence: "timekeeping/app/services/timekeeping/entry_writer.rb update_entry checks stored_values(entry).merge(fields), and app/services/timekeeping/reference_facts.rb returns every company agent, in PR #117 at f7eb21efa496a2ad86b248fa7a852a074cc80f62"
audience: both
related_components:
  - reference_endpoint
  - timekeeping_rules
  - projection
tags:
  - cross-field-invariant
  - update-validation
  - reference-facts
  - design-rule-s7
  - outbox
applies_when:
  - A write must keep a rule that ties two fields of one row together, such as agent_id and user_id
  - An update may change only one of the two fields
  - The facts the rule needs come from another service and are read before the row is locked
---

# Check the pair the row will hold, and fetch facts that cover stored values

## Context

Design rule S7 says an entry's agent must be an agent of the entry's company, and that agent's user must be the entry's user. The monolith's projection refuses a snapshot that breaks this rule. The relay only moves on after a success, so one refused snapshot holds back every later delivery. Timekeeping therefore has to refuse such a write before it commits.

Two easy designs miss cases:

- Checking only the `agent_id` in the request body. A `PATCH` that sends only `user_id` keeps the stored agent and changes its user. The row then holds an agent that belongs to someone else, and the body never named an agent.
- Asking the monolith only about the agent ids named in the request. The reference facts are read before the write's transaction opens. The stored `agent_id` is known only after the row is locked, so a lookup keyed on requested ids cannot include it.

## Solution

Check the pair the row will hold after the write, on every create and update:

```ruby
committed = stored_values(entry).merge(fields)
return WriteOutcome.refusal(:not_found) unless agent_owned?(command, committed["agent_id"], committed["user_id"])
```

On create, check the body's `agent_id` against the user that `target_user_id` resolved, not against the acting user.

Have the reference endpoint return the whole set the rule can need: every agent of the company, active or not, as `{ id, user_id }` only. The rule then works for a stored value as well as a requested one. Keep the list small on the wire by sending only the two ids, never names or metadata.

Keep the rule itself pure. `TimekeepingRules::EntryRules.agent_owner(agent_id:, user_id:, company_agents:)` is a decision table that takes a Hash of agent id to user id. The writer only builds the committed pair and asks the table.

The facts are still read before the transaction, so an agent moved or deleted in between can slip through. The projection's own agent checks stay as the backstop for that window.

## Why it matters

A check that reads only the request body passes an update that changes one field of the pair. That write commits, its snapshot is refused downstream, and every later entry waits behind it. A fact lookup keyed on request ids has the same gap from the other side. The same shape applies to any rule that ties two columns together and whose facts come from another service.

## Evidence

PR #117, head commit f7eb21efa496a2ad86b248fa7a852a074cc80f62:

- `timekeeping/app/services/timekeeping/entry_writer.rb`: `update_entry` builds `committed = stored_values(entry).merge(fields)` and calls `agent_owned?` with the committed `agent_id` and `user_id`. The comment on `agent_owned?` says the facts are read before the transaction, so the projection's checks stay as the backstop.
- `app/services/timekeeping/reference_facts.rb`: the new `agents` method plucks `:id, :user_id` from `company.agents.order(:id)`, with no filter on requested ids and no filter on `active`.
- `contracts/timekeeping/reference.yml`: adds `agent_fields: [id, user_id]` and extends the `company_scope` rule to list every agent of the company.
- `gems/timekeeping_rules/lib/timekeeping_rules/entry_rules.rb`: adds `AGENT_OWNER_TABLE` and `agent_owner`.
- `timekeeping/spec/services/timekeeping/entry_writer_spec.rb`: the example "refuses an update that changes only user_id away from the stored agent's user and writes nothing" sends a body with only `user_id` and expects 404 with unchanged row counts.
- `docs/architecture/timekeeping-soa.md`: records that the agents list is read before the write's transaction opens and that the projection still catches a change in that window.
