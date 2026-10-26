---
module: timekeeping_ownership
date: 2026-10-26
problem_type: design_pattern
component: timekeeping
severity: high
evidence_grounding: anchored
grounding_evidence: "app/models/timekeeping_ownership.rb in PR #149 adds TimekeepingOwnership#handoff_begun?, which compares generation, handoff_step, owner and monolith_store with the INITIAL_* constants; spec/models/timekeeping_ownership_spec.rb checks each column on its own and shows that the flip and abort states, with handoff_step nil, still count as begun."
audience: both
related_components:
  - seeds
  - api_layer
tags:
  - timekeeping-handoff
  - ownership-row
  - state-predicate
  - write-fence
applies_when:
  - A writer must be refused once a multi-step process has ever started, not only while it is running
  - The process tracks its current step in a column that later steps reset to nil
---

# Detect that a handoff has begun by departure from the initial state, not by the step marker

## Context

The `TimekeepingOwnership` row tracks a handoff with four columns: `generation`, `handoff_step`, `owner` and `monolith_store`. Some writers, such as the seeds, the demo seeder and the super-admin hard delete, may run only before any handoff has ever started.

The existing billing fence admits writes based on `handoff_step` alone. That is right for the billing fence, which only cares about an active handoff. It is wrong for "has a handoff ever begun":

- The flip to Timekeeping clears `handoff_step`, and it leaves `owner = "timekeeping"`.
- A rollback leaves `monolith_store = "prepared"` at a raised generation.
- An aborted handoff leaves the legacy store at a raised `generation`, with no step set.

In all three states, a check on `handoff_step` alone says "not begun" and lets the writer through.

## Solution

Define the rule as "any column differs from its initial value". Name the initial values once, as constants, and write the check against them:

```ruby
INITIAL_GENERATION = 1
INITIAL_OWNER = "monolith"
INITIAL_MONOLITH_STORE = "legacy"

def handoff_begun?
  generation > INITIAL_GENERATION ||
    !handoff_step.nil? ||
    owner != INITIAL_OWNER ||
    monolith_store != INITIAL_MONOLITH_STORE
end
```

Write the owner and store clauses as `!=` against the initial value, not `==` against known later values. Then an owner or store value added later counts as begun with no change to this method.

Keep this rule in one instance method. The class reader `TimekeepingOwnership.handoff_begun?`, `refuse_if_handoff_begun!` and `unless_handoff_begun` all call it, and they treat a missing row as begun.

Test each column on its own. Start from the initial row, change exactly one column, and expect `true`. Also test the flip and abort states with `handoff_step: nil`. A test that only sets `handoff_step` cannot tell this rule apart from the narrow one.

## Why it matters

The writers this rule guards bypass the Timekeeping service. A seed run or a hard delete after the flip writes data that Timekeeping never sees, and the hard delete cannot be undone. The state where the guard most needs to hold, after the flip, is exactly the state where the step marker is empty.

The trade-off is that an aborted handoff also blocks seeding and user deletion for every company, because the ownership row is global. This change accepts that cost: a fresh demo reset is the way back, which the `HandoffBegun` error message says.

Before you reuse the billing fence's `handoff_step` check, ask which question the guard answers. "Is a handoff running right now?" and "has a handoff ever begun?" need different rules.

## Evidence

- PR #149 adds `TimekeepingOwnership#handoff_begun?`, the `INITIAL_*` constants and the comment explaining why `handoff_step` alone cannot tell, in `app/models/timekeeping_ownership.rb`.
- In `spec/models/timekeeping_ownership_spec.rb`, the example "handoff_begun? is false only for the initial row and true when any single column leaves it" changes one column at a time. The example "still counts as begun after the flip or an abort has cleared handoff_step" covers owner `timekeeping` at generation 2 and legacy at generation 3, both with `handoff_step: nil`.
- `spec/requests/api/v1/users/destroy_spec.rb`, `spec/services/analytics/demo_seeder_spec.rb` and `spec/db/seeds_handoff_refusal_spec.rb` each run a four-state table: step set, owned by Timekeeping after the flip, prepared store after a rollback, and legacy store at generation 2.
