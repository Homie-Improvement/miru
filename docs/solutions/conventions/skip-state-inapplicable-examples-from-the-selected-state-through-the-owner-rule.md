---
module: spec/support/timekeeping
date: 2026-11-20
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - spec/services/imports
  - bin/timekeeping-demo
tags:
  - rspec-skip
  - owner-state
  - example-metadata
  - suite-hooks
  - timekeeping-regression
applies_when:
  - An example family only makes sense in some TIMEKEEPING_OWNER_STATE values, such as specs that assert on writes forwarded to Timekeeping
  - Adding a metadata tag that a suite hook turns into a skip
---

# Skip state-inapplicable examples from the selected state, through the owner rule

## Context

`bin/timekeeping-demo regression` runs the suite once per owner state: `legacy`, `timekeeping` and `rollback`. In `legacy` and `rollback` the monolith owns the entries, so `Timekeeping::Gateway` writes locally and nothing is forwarded. Examples that assert on requests the fake Timekeeping app received cannot pass there. They need to show up as skipped with a reason, not fail and not disappear.

A skip is easy to get wrong in ways that keep the run green while removing coverage.

## Solution

Tag the examples, and let one suite-level `before` hook in `spec/support/timekeeping/owner_state.rb` decide. Each tag in `OWNER_TAGS` names the `Timekeeping::EntryOwner` value its examples need and the reason given when they are skipped. `FORWARDS_TAG` (`:forwards_to_timekeeping`) needs `:timekeeping`; `LEGACY_STORE_TAG` (`:writes_legacy_store`) needs `:legacy`, for assertions on the legacy model's own write path:

```ruby
def entry_owner(state_name)
  columns = fetch(state_name).slice(*OWNERSHIP_COLUMNS)
  Timekeeping::EntryOwner.for(TimekeepingOwnership.new(columns))
end

def skip_reason(metadata)
  tags = OWNER_TAGS.select { |tag, _rule| metadata[tag] == true }
  return nil if tags.empty?

  state_name = for_example(metadata)
  return nil if state_name.nil?

  owner = entry_owner(state_name)
  tags.each_value.find { |rule| rule[:owner] != owner }&.then { |rule| rule[:reason].call(state_name) }
end

config.before do |example|
  reason = TimekeepingOwnerState.skip_reason(example.metadata)
  skip reason if reason
end
```

`forwarding_skip_reason(metadata)` remains, as `skip_reason` for the forwarding tag alone, and `forwards_writes?(state_name)` remains as `entry_owner(state_name) == :timekeeping`.

Four rules make this safe:

1. **Read the selected state with `for_example`, never `current`.** `TimekeepingOwnerState.current` answers `"legacy"` when nothing is selected, because that is the row the cleaners leave. A skip keyed on it would hide the tagged examples in every ordinary run. `for_example` returns nil when no state is selected, and nil means "run".
2. **Ask the app's own rule.** `entry_owner` builds a `TimekeepingOwnership` from the state's columns and asks `Timekeeping::EntryOwner.for`, the rule the gateway dispatches on. No list of states per owner is kept in the spec harness, so it cannot drift from the gateway.
3. **An unknown state raises.** `entry_owner` goes through `fetch`, which raises `ArgumentError` naming `legacy, timekeeping, rollback`. A typo such as `"legcy"`, `"Rollback"` or `"rollback "` fails the example. If it answered false instead, the typo would skip the forwarded examples and the run would stay green.
4. **Decide per example, in a suite hook, with `skip` and a reason.** The check reads `== true` on the example's own metadata, so one example can opt out with `forwards_to_timekeeping: false`. A suite `before` hook runs before group hooks, so a skipped example builds no committed rows, fake registrations or HTTP routes. A runtime `skip` shows the reason in the output; a filter would drop the examples without saying so.

## Why it matters

Each mistake above produces a passing run. The cost is lost coverage that nobody sees: the forwarded-import examples are the only proof that imports reach Timekeeping. So the tests for a skip like this must prove both sides. They must show the skip fires in the states that do not forward. They must also show the example still runs, and a failing body still fails, in the `timekeeping` state and with no state selected.

## Evidence

- PR #480 adds `FORWARDS_TAG`, `forwards_writes?`, `forwarding_skip_reason` and the `config.before` skip hook in `spec/support/timekeeping/owner_state.rb`. The hook's comment states that suite hooks run before group hooks, so a skipped example builds none of its group setup.
- `spec/meta/timekeeping_owner_state_spec.rb` ("more tests 27") stubs `TimekeepingOwnerState::SELECTED` to nil and asserts `TimekeepingOwnerState.current` equals `"legacy"`, while a tagged example still runs and passes.
- The same spec checks that misspelt states (`"Legacy"`, `"rollback "`, `"bogus"`, `""`, nil, `"legcy"`) raise `ArgumentError` instead of skipping, and that a tagged example in the `timekeeping` state runs and a failing body fails ("more tests 19", "more tests 26").
- "more tests 20" and "more tests 28" check that untagged examples and examples with `forwards_to_timekeeping: false` run in the `legacy` state.
- `spec/services/imports/harvest_time_entries_importer_spec.rb` tags the four forwarded `RSpec.describe` groups with `forwards_to_timekeeping: true`.
- PR #491 turns the single forwarding check into the `OWNER_TAGS` table read by `skip_reason`, adds `LEGACY_STORE_TAG`, and tags the importer's two legacy-model assertions with `writes_legacy_store: true`. `spec/meta/timekeeping_owner_state_spec.rb` ("more tests 3", "more tests 4") checks the new tag in each state and for an unknown state.
