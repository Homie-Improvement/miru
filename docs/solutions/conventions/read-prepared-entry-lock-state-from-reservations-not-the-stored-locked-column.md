---
module: timekeeping
date: 2026-11-15
problem_type: convention
component: timekeeping_gateway
severity: medium
audience: both
related_components:
  - entry_lookup
  - local_entry
tags:
  - prepared-store
  - reservations
  - locked
  - hydration
applies_when:
  - Code reads Timekeeping::LocalEntry rows and turns them into TimesheetEntry models
  - A later step runs model validations that check whether the entry is locked
---

# Read a prepared entry's lock state from reservations, not the stored locked column

## Context

In the prepared store, an entry is locked while an invoice reservation holds it. The `entries` table also has a `locked` column, but that column is not kept current. A released reservation can leave it `true`.

The gateway hydrates `LocalEntry` rows into `TimesheetEntry` models and runs model checks on them. A bulk move keeps only entries that pass `valid?(:update)`, and the model refuses an employee's change to a locked entry. If hydration copies the stored column, an unlocked entry looks locked. The move skips it, and the request still answers success.

## Solution

Read the row through `LocalEntry.with_reserved` and set `locked` from the computed `reserved` value:

```ruby
row = LocalEntry.with_reserved.where(company_id: context.company.id, discarded_at: nil).find(entry_id)
fields = row.attributes.except("reserved").merge("locked" => row.reserved)
```

Apply the same rule to any new reader of `LocalEntry` that feeds model validations or a client answer.

## Why it matters

The failure is silent. Nothing raises, the client sees success, and the entry stays on its old project. The local owner would have allowed the move, so the gateway's own check is the only thing that blocks it.

## Evidence

- PR #319, `app/services/timekeeping/entry_lookup.rb`: the new `local_entry` method reads `LocalEntry.with_reserved` and merges `"locked" => row.reserved`. Its comment states that the stored `entries.locked` column is not kept current and that a stale true would make the model refuse a change the local owner allows.
- PR #319, `spec/services/timekeeping/entry_lookup_spec.rb`: "reads a prepared entry whose stale stored locked column is true but has no reservation as unlocked" and "reads a local entry holding a reservation as locked".
- PR #319, `spec/services/timekeeping/gateway_spec.rb`: "moves a prepared entry whose reservation was released though its stored locked column is still true" expects `written` true and the new project id.
