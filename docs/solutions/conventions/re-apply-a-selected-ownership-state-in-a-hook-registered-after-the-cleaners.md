---
module: Timekeeping test harness
date: 2026-11-18
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - RSpec
  - TimekeepingOwnership
  - database cleaner
tags:
  - ownership-state
  - before-hook
  - support-file-load-order
  - committed-data
applies_when:
  - A suite must run with the Timekeeping ownership row in a chosen state while cleaners reset that row between examples.
---
# Re-apply a selected ownership state in a hook registered after the cleaners

## Context

The cleaners in `spec/support/database_cleaner.rb` and `spec/support/committed_data.rb` call `TimekeepingOwnership.ensure_initial!` after they empty tables. That puts the ownership row back to legacy. Setting a state once at suite start therefore holds only until the first cleaner runs. Every later example silently runs under legacy, and a suite meant to prove behaviour under the timekeeping or rollback owner proves nothing.

## Solution

`spec/support/timekeeping/owner_state.rb` registers a per-example hook that re-applies the selected state:

```ruby
if TimekeepingOwnerState::SELECTED
  config.before do
    TimekeepingOwnerState.apply!(TimekeepingOwnerState::SELECTED)
  end
end
```

- The hook must run after the cleaners' hooks. `spec/rails_helper.rb` requires support files in sorted order, so a file under `spec/support/timekeeping/` registers after `committed_data.rb` and `database_cleaner.rb`. Moving or renaming the file can break that order.
- Register the hook only when a state is selected, so an unset variable leaves the suite as before. The change proves this with a probe that sets the row to rollback in `before(:all)` and checks it survives with the variable unset.
- `apply!` must update, not insert. `ensure_initial!` leaves an existing row unchanged, so `apply!` calls it and then `update_all` with every ownership column, including `handoff_step` and `final_outbox_position` set to nil, so no stale handoff column remains.
- Prove survival with a real cleaner: the probe runs a `committed_data: true` example first, in defined order, then checks the row.
- Check the row right before the operation under test with `expect_owner_state!`. It compares owner, `monolith_store`, generation and whether `legacy_retired_at` is set as well as `Timekeeping::EntryOwner.for`, because `EntryOwner.for` gives the same answer for different generations.

## Why it matters

The failure is silent: specs keep passing, just under the wrong owner. Only a hook ordered after the reset, and a check that reads the raw columns, makes the chosen state real for every example.

## Evidence

- PR #373, `spec/support/timekeeping/owner_state.rb`: the header comment explains the cleaner reset and sorted load order; the `config.before` hook is registered only `if TimekeepingOwnerState::SELECTED`; `apply!` calls `ensure_initial!` then `update_all` over `OWNERSHIP_COLUMNS`.
- PR #373, `spec/fixtures/timekeeping_harness/owner_state_probe.rb`: `order: :defined`, a `committed_data: true` example first, then an example that checks the selected state.
- PR #373, `spec/fixtures/timekeeping_harness/unset_owner_state_probe.rb` and the example in `spec/meta/timekeeping_owner_state_spec.rb` that asserts generation 4 on a rollback row still gives `:prepared` from `EntryOwner.for` while `expect_owner_state!("rollback")` fails.
