---
module: spec/support/timekeeping
date: 2026-11-21
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - owned_entries
tags:
  - spec-helpers
  - filters
  - argument-error
  - no-write-check
applies_when:
  - Writing a spec reader that takes `**filters` and keeps rows whose fields equal them
  - Specs use the reader in `be_empty`, `eq([])` or `not_to change` assertions
---

# Raise on unknown filter keys in spec entry readers

## Context

`owned_entries(company: nil, state:, include_discarded: false, **filters)` keeps entries whose fields equal the given values. A plain `filters.all? { |field, value| entry[field] == value }` does not fail on a misspelt key. With `notes:` instead of `note:`, `entry["notes"]` is nil, so the read returns nothing. An `expect(...).to be_empty` or a `not_to change` check then passes while matching entries exist.

## Solution

List the allowed keys once and refuse anything else before reading:

```ruby
OWNED_ENTRIES_FILTERS = %w[project_id user_id note duration work_date bill_status source].freeze

unknown = filters.keys - OWNED_ENTRIES_FILTERS
raise ArgumentError, "unknown owned entry filters: #{unknown.join(', ')}" if unknown.any?
```

Refuse an unknown state the same way: `TimekeepingOwnerState.fetch(state)` raises before any store is read. Pin both refusals in the reader's own spec, next to a control that the correct key still finds the row.

## Why it matters

Negative assertions are the ones a silent typo turns into no test at all. The reader is shared by many examples, so one refusal in the reader protects every one of them.

## Evidence

- PR #538, `spec/support/timekeeping/owned_entries.rb`: adds `OWNED_ENTRIES_FILTERS` and raises `ArgumentError` for unknown keys before calling the per-state lister.
- PR #538, `spec/integration/timekeeping/owned_entries_spec.rb`: the example "owned_entries refuses an unknown filter key or state instead of silently matching every entry" expects `ArgumentError` for `notes:` and for state `"Legacy"`, and expects `note: "only"` to return one row.
