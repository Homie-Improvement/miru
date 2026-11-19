---
module: Timekeeping owner state harness
date: 2026-11-19
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - TimekeepingOwnerState.apply!
  - spec/meta/timekeeping_owner_state_spec.rb
tags:
  - table-driven-specs
  - spec-refactor
  - starting-state
  - rspec
applies_when:
  - Splitting one example that loops over states into one generated example per state
  - Testing a writer that sets only the keys a table such as STATES holds
---

# Keep loop-carried state as a named starting row when you split a loop example into rows

## Context

Old specs often check several cases in one example with a loop. Each pass of that loop starts from whatever the previous pass wrote. Some setup is re-applied each pass, but any column that setup does not touch keeps the previous pass's value.

When such an example becomes one generated `it` per row, each row starts clean. The inherited values are gone, and nothing in the old setup lines shows that they were ever there.

This matters most for a writer that sets only the columns its table names. `TimekeepingOwnerState.apply!` writes only the keys `STATES` holds for a state. If a key is dropped from `STATES`, the column keeps its starting value. A test can then catch that bug only if the starting value differs from the target.

## Solution

Make the starting row its own table dimension, give each starting row a name, and put that name in the example description. Build the list of starting rows from two sources:

- the explicit setup of every removed example;
- the state each loop pass inherited from the passes before it. For example, rollback applied after timekeeping starts from owner `timekeeping`, store `legacy` and `legacy_retired_at` set.

Then check coverage column by column. Every column the writer must set needs at least one starting row where it holds a value other than its target, for every state.

The rewritten `.apply!` group does this with `apply_seeds`. Each seed lists the state applied first (nil for the column defaults) and the columns written over it:

```ruby
apply_seeds = {
  "a mid-handoff monolith-owned row" => { applied: nil, columns: mid_handoff },
  "a mid-handoff timekeeping-owned row with legacy_retired_at nil" => { ... },
  "the applied rollback row" => { applied: "rollback", columns: {} },
  "a mid-handoff row after timekeeping was applied" => { applied: "timekeeping", columns: mid_handoff }
}
```

Each state is applied over every seed except the applied rollback row (the writes rows iterate `apply_seeds.except("the applied rollback row")`), and each example is titled `writes exactly the ... columns over #{seed_name}`. The refusal rows (bogus, empty string, ROLLBACK, nil) also run over the applied rollback row. A refusal that first cleared `legacy_retired_at` changes nothing on a row where it is already nil, so only that seed can catch it.

## Why it matters

A rewritten table can keep every listed input and still check less than the old file did. The new rows pass, the old example is gone, and a dropped key in `STATES` goes unnoticed. Checks that compare against `STATES` itself, such as `expect_owner_state!`, cannot catch this, because they read the same wrong value.

To prove each seed earns its place, change the code under test for a moment. For example, remove one key from a state's entry. A named seed row must then fail. Restore the code afterward.

## Evidence

PR #376 rewrites `spec/meta/timekeeping_owner_state_spec.rb`. Its `.apply!` group adds the `apply_seeds` table and a `seed_ownership` helper. A comment there says each owner column `apply!` must write starts from a value other than its target in at least one row. The comment also says the row after timekeeping makes rollback change owner and store together.

Review of this pull request found three lost inputs in earlier versions of the rewrite:

- The monolith-owned starting row was missing. With `owner: "timekeeping"` removed from `STATES["timekeeping"]`, the restored row failed: 15 examples, 1 failure.
- The applied rollback row was missing from the refusal examples. A temporary `update_all(legacy_retired_at: nil)` at the start of `apply!` made the four refusal rows over that seed fail: 15 examples, 4 failures.
- The removed persistence example applied legacy, timekeeping and rollback in sequence. Rollback therefore started from timekeeping's row, and that inherited state was lost. With owner and store removed from `STATES["rollback"]`, the new seed "a mid-handoff row after timekeeping was applied" failed: 18 examples, 4 failures.
