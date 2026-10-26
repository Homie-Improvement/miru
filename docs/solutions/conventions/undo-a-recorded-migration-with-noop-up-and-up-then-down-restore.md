---
module: db/migrate
date: 2026-10-26
problem_type: convention
component: database
severity: high
evidence_grounding: anchored
grounding_evidence: In commit 1d86bafc, db/migrate/20261020120000_drop_timesheet_entry_foreign_keys.rb changes up to `def up; end` and keeps down. The spec 'restores the keys through the migration runner when an interrupted drop left the version unrecorded' in spec/db/migrations/drop_timesheet_entry_foreign_keys_spec.rb runs runner up then down. docs/architecture/timekeeping-soa.md section 10.2 gives the one-off-container rule and the UnknownMigrationVersionError reason.
audience: both
related_components:
  - deployment
  - testing_framework
tags:
  - migrations
  - schema-migrations
  - foreign-keys
  - rolling-deploy
  - rollback
  - disable-ddl-transaction
applies_when:
  - A migration that already shipped did something unsafe, and some databases have run it
  - The migration disables its DDL transaction and changes several objects one at a time
  - Operators must restore the migration's effect before a deploy
---

# Undo a recorded migration with a no-op up and an up-then-down restore

## Context

A migration shipped that dropped three foreign keys too early. Rails records each run migration's version in `schema_migrations` and never runs it again. So editing the body only changes databases that have not run it yet. Databases that already ran it keep the old result until someone acts.

Three traps sit in the obvious fixes:

- Deleting or renumbering the migration orphans its recorded version. Those databases then lose the `down` that is their only restore path.
- Making `up` re-add what the old body removed fails on any row written while the protection was gone.
- The old body removed keys one at a time outside a transaction. An interrupted run can drop a key without ever recording the version. `bin/rails db:migrate:down VERSION=...` skips an unrecorded version, so it restores nothing.

## Solution

1. Keep the version, class name and `down`. Make `up` do nothing, and say why in a comment:

   ```ruby
   # Removes nothing, and adds back nothing: re-adding a key here would fail on
   # any row written while it was absent.
   def up; end
   ```

2. Put the restored objects back in `db/schema.rb`, so a fresh schema load and a migrate-from-empty agree.
3. Keep the guard in `down` that refuses, without changing data, when rows would break the restore.
4. Restore with up first, then down:

   ```
   bin/rails db:migrate:up db:migrate:down VERSION=20261020120000
   ```

   `up` records an unrecorded version and changes nothing. It does nothing when the version is already recorded. Then `down` runs in both cases.
5. Run that command in a one-off container of the release being deployed, never a running one. The old release does not have the edited file, so the command there stops with `UnknownMigrationVersionError`. With Kamal, use `kamal app exec --version=<new version>` without `--reuse`. Aliases that use `--reuse` run in a running container too.

In specs, remove the objects first when the schema now declares them again. Otherwise a restore example that uses `if_not_exists: true` adds nothing and passes even with the restore code deleted.

## Why it matters

If you skip any of these, the restore fails without warning on exactly the databases that need it. A half-migrated database looks recorded-clean to `down`. An old container looks like it can run the command but cannot. Either way, old processes keep writing with no protection during the rolling deploy.

## Evidence

- PR #51, head commit 1d86bafc1df845089b52bd5c7b41ee2021f9f9e7.
- `db/migrate/20261020120000_drop_timesheet_entry_foreign_keys.rb`: `up` replaced by `def up; end` with the comment above; `down` unchanged.
- `db/schema.rb`: adds `add_foreign_key` lines for `invoice_line_item_time_entries` and `invoice_line_items` to `timesheet_entries`, and `timesheet_entries` to `agents`.
- `spec/db/migrations/drop_timesheet_entry_foreign_keys_spec.rb`: the example 'restores the keys through the migration runner when an interrupted drop left the version unrecorded' deletes the version row, removes one key, runs the migration context `run(:up, version)` then `run(:down, version)`, and checks all three keys present and validated. The rollback examples now call `remove_dropped_keys` before `down`.
- `docs/architecture/timekeeping-soa.md` section 10.2: the restore steps state that `db:migrate:down` skips a version that is not recorded, and that a running old container stops with `UnknownMigrationVersionError`.
