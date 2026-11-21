---
module: timekeeping_rules
date: 2026-11-21
problem_type: design_pattern
component: timekeeping_rules
severity: medium
audience: both
related_components:
  - timekeeping
  - authorization
tags:
  - background-operations
  - allowlist
  - unknown-caller
  - entry-rules
applies_when:
  - A caller stops using a name in TimekeepingRules::EntryRules::BACKGROUND_OPERATIONS
  - Adding or removing a background operation name
---

# Remove background operation names no caller mints, and pin their refusal

## Context

The rules gem treats every name in `TimekeepingRules::EntryRules::BACKGROUND_OPERATIONS` as a background job. A background caller skips the user rules: the lock, the edit window and ownership. `entries.import` stayed in the list after the Harvest import started to write as its import user, so no code minted a token for it. The name was still a working way to skip those rules.

## Solution

When no code mints a background name, delete it from the constant. Do not keep it with a note that says it is unused. `check_caller!` does not change: an unlisted name raises `UnknownCaller` from `change_decision`, `refusing_rules` and `bulk_decision`.

Then make the removal hard to undo by accident:

- Add the removed name to the unknown-caller table in `caller_spec.rb`.
- Pin the constant to the exact list with `eq`, and keep the `be_frozen` checks.
- Loop the acceptance example over the constant itself instead of a hand-copied list, so the spec has one source for the names.
- Rewrite specs that used the name as a working caller to use a live name, with the same entry state and expectation.
- Remove the name from the prose that lists the allowlist, such as sections 6.2 and 7.3 of `docs/architecture/timekeeping-soa.md`.

## Why it matters

An allowlist entry with no caller is a rule exception nobody needs. Any future service that holds the name gets the skip, and no one reviews that choice. The exact pin and the refusal row mean that adding the name back fails a spec, so it becomes a deliberate decision.

## Evidence

- PR #533 deletes `entries.import` from `BACKGROUND_OPERATIONS` in `gems/timekeeping_rules/lib/timekeeping_rules/entry_rules.rb`.
- `gems/timekeeping_rules/spec/timekeeping_rules/entry_rules/caller_spec.rb` adds `"entries.import"` to the unknown-caller table, replaces the hand-copied six-name list with a loop over the constant, and pins the constant with `eq` to the five live names.
- `change_decision_spec.rb` now uses `agents.detach_entries` and `bulk_decision_spec.rb` uses `reservations.abort`, each keeping its `:ok` or `10 => :apply` expectation.
- `docs/architecture/timekeeping-soa.md` drops the name from sections 6.2 and 7.3 and says the Harvest import writes user-delegated.
- The author ran the caller spec filtered to `entries.import`: 4 examples, 0 failures.
