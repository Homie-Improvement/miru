---
module: timekeeping_rules
date: 2026-10-25
problem_type: convention
component: timekeeping_rules
severity: low
evidence_grounding: anchored
grounding_evidence: "In gems/timekeeping_rules/lib/timekeeping_rules/entry_rules.rb, PR #41 changes both CHANGE_RULES and TARGET_USER_TABLE from `].freeze` to `].map(&:freeze).freeze`. It also adds `be_frozen` and `all(be_frozen)` specs in change_decision_spec.rb and target_user_spec.rb."
audience: both
related_components:
  - entry_rules
tags:
  - ruby
  - freeze
  - decision-table
  - rspec
  - random-order
applies_when:
  - Adding or changing a constant decision table whose rows are arrays of lambdas and outcomes
  - Writing a spec that proves a shared constant cannot be changed
---

# Freeze rule table rows, not only the outer array

## Context

The timekeeping rules gem makes its decisions from two constant tables in `TimekeepingRules::EntryRules`. `CHANGE_RULES` holds `[rule_id, binds, refuses]` rows. `TARGET_USER_TABLE` holds `[condition, outcome]` rows. Each table ended in `].freeze`.

In Ruby, `freeze` is shallow. It stops rows from being added to or removed from the outer array. It does not stop anyone from writing into a row. A line such as `CHANGE_RULES[0][2] = ->(_) { false }` worked. It swapped a rule's check, and that changed every later decision in the process without any error.

## Solution

Freeze each row, then the outer array:

```ruby
CHANGE_RULES = [
  [:a4, ->(facts) { ... }, ->(facts) { ... }],
  # ...
].map(&:freeze).freeze
```

With this, writing into a row raises `FrozenError`. The lambdas inside the rows stay unfrozen. A frozen row already stops anyone from replacing a lambda, and freezing a Proc does not change what calling it returns.

To prove it, check the frozen state. Do not try a write:

```ruby
expect(TimekeepingRules::EntryRules::CHANGE_RULES).to be_frozen
expect(TimekeepingRules::EntryRules::CHANGE_RULES).to all(be_frozen)
```

`all(be_frozen)` fails if even one row is left unfrozen. A spec that tries to write to a row is unsafe. The gem's suite runs in random order, so a write that succeeds on an unfrozen table changes the constant for every example that runs after it.

## Why it matters

These tables are the single source of truth for which time-entry changes are allowed. One accidental write from any code that loads the gem can change authorization results across the whole process, and nothing raises an error. A new table written with only `].freeze` looks safe in review but has the same gap. The same shallow-freeze rule applies to any constant that holds nested arrays or hashes.

## Evidence

- PR #41, head commit 1dc69b277b732ca64f1e04127bd807af18b8c7c7, closes issue #37.
- `gems/timekeeping_rules/lib/timekeeping_rules/entry_rules.rb`: both `CHANGE_RULES` and `TARGET_USER_TABLE` change from `].freeze` to `].map(&:freeze).freeze`.
- `gems/timekeeping_rules/spec/timekeeping_rules/entry_rules/change_decision_spec.rb` adds `it "keeps the change rule table and each of its rows frozen"`, which uses `be_frozen` and `all(be_frozen)`.
- `gems/timekeeping_rules/spec/timekeeping_rules/entry_rules/target_user_spec.rb` adds the same check for `TARGET_USER_TABLE`.
- The PR body says neither spec tries a write because the suite runs in random order. It also says both specs failed before the fix and the gem suite then passed with 87 examples and 0 failures.
