---
module: spec/support/timekeeping
date: 2026-11-21
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - timekeeping
  - reservations
tags:
  - checkpoint
  - fixtures
  - locked-entries
  - reservations
  - owner-state
applies_when:
  - A spec helper arranges fixtures by loading a checkpoint that replaces whole tables
  - The store that owns the data derives a fixture attribute from rows in another table
  - Several ownership states each have their own fixture writer for the same attribute
---

# Load the rows a store derives a fixture flag from in the same checkpoint

## Context

In the timekeeping ownership state, `arrange_owned_entries` writes fixtures by loading a `Timekeeping::Handoff::Checkpoint`. A checkpoint load replaces whole tables. The helper `TimekeepingOwnedEntries.checkpoint_of` used to take only entry rows and fill every other table with `[]`.

Timekeeping does not trust the entry's own `locked` column. It treats an entry as locked only when a reservation of the same company holds it. So a fixture arranged with `locked: true` loaded with an empty `reservations` table and read back unlocked. Nothing failed: the model and rules specs that pin locked-entry behaviour passed against an entry that was not locked at all.

## Solution

When a store derives a fixture attribute from another table, write that table's rows in the same load:

- `checkpoint_of` now takes a hash of table name to rows, so a caller can name every table it needs. Tables it does not name stay empty.
- `load_timekeeping_entries` builds one reservation row for each entry whose `locked` is true, and loads it in the same checkpoint as the entries.
- The per-example cache `@timekeeping_owned_tables` keeps both `entries` and `reservations`. A later arrange call reloads both, so earlier locked entries stay locked. The cache is set only after the load succeeds, so a retried batch does not get a second reservation.
- Both writers that create a locked fixture get their row from one pure builder, `TimekeepingOwnedEntries.fixture_reservation_row(entry, stamp, operation_id:)`. These are the timekeeping checkpoint writer and the rollback writer `insert_fixture_reservation`. Each writer draws `SecureRandom.uuid` itself and passes it in, so the builder stays deterministic.

Prove the attribute through the store's own reader, not only through the rows you wrote. The live example reads `owned_entry(id, state: "timekeeping").fetch("locked")` for a locked entry and an unlocked one, then reads it again after a second arrange.

## Why it matters

A fixture attribute that is dropped this way fails open. Specs that should guard the locked rules keep passing, and they stop testing anything. Reading the attribute back through the real reader is the only check that catches the gap.

One shared builder means the timekeeping and rollback states write the same reservation values. Without it, a change to the reservation shape could lock fixtures in one state and not the other.

The same risk applies to any other attribute that a checkpoint-backed store derives from a second table. Check which table the store reads before you trust a column on the main row.

## Evidence

- PR #531 changes `spec/support/timekeeping/owned_entries.rb`. It adds `fixture_reservation_row`. It changes `checkpoint_of(tables)` to fill only the tables a caller does not name with `[]`. It makes `load_timekeeping_entries` add one reservation per locked entry and cache both tables in `@timekeeping_owned_tables` after `load_while_fenced` returns. It rewrites `insert_fixture_reservation` to insert the builder's row.
- PR #531 adds examples to `spec/integration/timekeeping/owned_entries_spec.rb`:
  - A live example reads a locked fixture as locked, an unlocked one as unlocked, and the first entry as still locked after a second arrange.
  - Injected-store examples check one reservation per locked row, each under its own company, kept across a later load and not duplicated after a failed load.
  - Legacy and rollback examples check that locked fixtures still read locked in those states.
- In this pull request, a comment in `spec/support/timekeeping/owned_entries.rb` states the rule: Timekeeping and the prepared store treat an entry as locked exactly when a reservation of its company holds it.
