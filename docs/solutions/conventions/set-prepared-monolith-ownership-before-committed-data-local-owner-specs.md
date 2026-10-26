---
module: timekeeping
date: 2026-10-26
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: anchored
grounding_evidence: "spec/services/timekeeping/local_owner_concurrency_spec.rb before block: comment says the committed-data reset leaves ownership with the legacy store, which LocalOwner refuses as stale_generation, then calls TimekeepingOwnership.current.update!(owner: 'monolith', monolith_store: 'prepared', handoff_step: nil)"
audience: both
related_components:
  - TimekeepingOwnership
  - Timekeeping::LocalOwner
tags:
  - committed-data
  - ownership
  - stale-generation
  - fixtures
applies_when:
  - "Writing a committed_data: true spec that calls Timekeeping::LocalOwner"
---

# Set prepared monolith ownership before committed-data LocalOwner specs

## Context

Specs tagged `committed_data: true` commit real rows so that two connections can see each other's work. After each example the tables are emptied and ownership is reset. That reset leaves `TimekeepingOwnership` with the legacy store. `Timekeeping::LocalOwner` treats that state as not admitted and answers 409 `stale_generation`.

## Solution

In a `before` block, set ownership to the state LocalOwner admits, then read the generation after that:

```ruby
before do
  TimekeepingOwnership.current.update!(owner: "monolith", monolith_store: "prepared", handoff_step: nil)
end

let!(:generation) { TimekeepingOwnership.current.generation }
```

Read the generation once on the test's own thread, before any thread can start a handoff that changes the row.

## Why it matters

Without this setup, a test that expects a 200 fails with what looks like a real fence refusal. Worse, a test that expects `stale_generation` from a concurrent handoff passes for the wrong reason, and would keep passing if the handoff lock were removed.

## Evidence

- PR #185 adds `spec/services/timekeeping/local_owner_concurrency_spec.rb`. Its `before` block carries the comment about the committed-data reset and the legacy store, and runs the `update!` shown above.
- The same file reads `generation` in a `let!` with the comment that it is read once on the test's own thread, before any handoff can change it.
- The example "refuses a LocalOwner update that queued behind an uncommitted handoff once the handoff commits" expects `[409, { "reason" => "stale_generation" }]`, which is the answer this setup keeps from happening by accident.
