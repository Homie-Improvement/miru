---
module: spec/services/invoices
date: 2026-10-27
problem_type: convention
component: testing_framework
severity: low
evidence_grounding: anchored
grounding_evidence: "PR #249 deletes the redelivery-orderings example from spec/services/invoices/prepared_reservations_spec_layout_spec.rb and adds \"redelivered commit and late abort\" to the group list of the 'keeps each cited contract group exactly once' example, after a review finding that its `expect(owners.size).to eq(1)` pin was lost."
audience: both
related_components:
  - layout specs
  - spec/services/invoices/prepared_reservations_spec.rb
tags:
  - layout-spec
  - duplicate-tests
  - spec-structure
applies_when:
  - Moving content assertions out of a layout spec into the behavioral spec
  - Deleting an example from a spec that guards against duplicated examples
---

# Keep an owner count for every contract when trimming a layout spec

## Context

`spec/services/invoices/prepared_reservations_spec_layout_spec.rb` exists to stop near-copies of examples from coming back into `prepared_reservations_spec.rb` after they were merged. Its rule is that the layout spec holds group and example counts, and the behavioral spec holds request inputs, outcomes and stored-state checks.

Some layout examples mixed both jobs. The redelivery example matched source text for `.commit(` and `.abort(` calls and the settled states, and it also asserted `expect(owners.size).to eq(1)`. Removing the content checks by deleting that example whole also removed the only count for that contract. A copy of the redelivery example could then be added back and the layout spec would still pass.

## Solution

When you strip content checks from a layout example, keep its count. If the example is going away entirely, move its contract into a structural count that does not read content. In this change the redelivery group joined the list that requires exactly one nested `describe` holding exactly one `it`:

```ruby
[
  "reclaiming a retained entry", "operation never stored", "unresolved operation", "mark_billed",
  "redelivered commit and late abort"
].each do |group|
```

The other trimmed examples (`unresolved_operation`, `not_found`) kept their `eq(1)` lines and lost only the content matches.

Before you finish, list every contract the layout spec guarded before the change. Then check that each one still has a count after it.

## Why it matters

The behavioral spec stays green whether or not a duplicate exists, so no failing test will tell you the guard is gone. The only protection against duplication drifting back is the count. Losing it is invisible until someone re-adds the copy the merge removed.

## Evidence

- PR #249 removes the "runs both redelivery orderings inside one example" example from `spec/services/invoices/prepared_reservations_spec_layout_spec.rb`, including its `expect(owners.size).to eq(1)`.
- A review finding on that change noted that nothing then pinned the redelivery contract to one owner. The fix added "redelivered commit and late abort" to the group list and reworded the comment to say this group is counted so a near-copy cannot come back.
- The author's recorded check inserted a second `it` into that group and confirmed the layout spec's extraction counts 2 examples, so the `eq(1)` check fails.
