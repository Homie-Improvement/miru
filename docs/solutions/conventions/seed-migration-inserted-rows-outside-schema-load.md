---
module: Timekeeping
date: 2026-10-25
problem_type: convention
component: database
severity: medium
evidence_grounding: anchored
grounding_evidence: "PR #44: app/models/timekeeping_ownership.rb defines ensure_initial! and a raising current; db/seeds.rb and spec/support/database_cleaner.rb call ensure_initial!; spec/db/seeded_entry_company_spec.rb deletes the row then loads seeds."
audience: both
related_components:
  - timekeeping_ownership
  - db_seeds
  - database_cleaner
tags:
  - migrations
  - schema-load
  - singleton-row
  - seeds
  - test-setup
applies_when:
  - A migration inserts a row that the application requires to exist
  - Adding a singleton or configuration table
---

# Seed migration-inserted rows outside schema load

## Context

`db/schema.rb` records tables, not rows. A row that a migration inserts exists only on databases that ran that migration. A database built with `db:prepare` or `db:schema:load` has the table but no row. The test suite also loses the row when its cleaner truncates or deletes every table.

PR #44 adds `timekeeping_ownership`, which must always hold exactly one row (generation 1, owner `monolith`). The first plan had `TimekeepingOwnership.current` create the row when missing. Review rejected that: it treats a fresh database and lost ownership state as the same thing, and hands later callers an invented owner.

## Solution

Split creating the row from reading it.

- `TimekeepingOwnership.current` does `find(SINGLETON_ID)` and raises `ActiveRecord::RecordNotFound` when the row is gone.
- `TimekeepingOwnership.ensure_initial!` does `insert_all([{ id: SINGLETON_ID }], unique_by: :id)`. It takes every other value from the column defaults, so the initial state lives in one place, and it leaves an existing row unchanged.

Call the initializer everywhere a database can come up without the migration having run:

- the migration itself, as an `INSERT ... ON CONFLICT (id) DO NOTHING`;
- `db/seeds.rb`, which `db:prepare` runs on a new database;
- `spec/support/database_cleaner.rb`, right after each truncation or deletion.

Test the setup path from an empty table, without calling the initializer in the test, so a removed seed call fails the spec.

## Why it matters

Without this, fresh installs and CI quietly differ from migrated databases. The first code that reads the row fails only there, or worse, a lazy default masks state that was actually lost.

## Evidence

PR #44, head commit `9ee9f2d66a4aeb1560bcdf330cd68ab38e7d536b`:

- `app/models/timekeeping_ownership.rb` defines `current` (raising) and `ensure_initial!`, with a comment that a database loaded from `db/schema.rb` has no rows.
- `db/migrate/20261025120000_prepare_monolith_for_timekeeping.rb` sets the column defaults, the `id = 1` check, and inserts the row on migrate.
- `db/seeds.rb` calls `TimekeepingOwnership.ensure_initial!` before seeding companies.
- `spec/support/database_cleaner.rb` calls `ensure_initial!` after the suite truncation and after the system-spec deletion.
- `spec/db/seeded_entry_company_spec.rb` runs `TimekeepingOwnership.delete_all`, loads `db/seeds.rb`, and expects one row `[1, "monolith", nil]`.
- `spec/models/timekeeping_ownership_spec.rb` checks that `current` raises when the row is missing and that `ensure_initial!` leaves a generation 3 row unchanged.
