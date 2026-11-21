---
module: db/migrate
date: 2026-11-21
problem_type: convention
component: database
severity: medium
audience: both
related_components:
  - testing_framework
tags:
  - migration-specs
  - schema-version
  - foreign-keys
  - loaded-schema
applies_when:
  - Writing a spec under spec/db/migrations for a migration
  - Adding a migration that changes keys, columns or the version that older migration specs read
---

# Arrange the schema state a migration spec needs instead of reading the loaded schema

## Context

The test database is built from `db/schema.rb`, which reflects the newest migration, not the one a spec is about. A migration spec that reads that loaded state works only while its migration is the newest. When a later migration moves the version on or drops a constraint, the old spec fails. Nothing is broken; the spec simply assumed the database stopped at its own migration.

PR #508 adds a migration that drops three foreign keys and moves the schema version to `2026_11_21_120000`. Two older migration specs broke for this reason:

- `spec/db/migrations/add_settling_to_timekeeping_ownership_spec.rb` required `db/schema.rb` to declare exactly its own version.
- In `spec/db/migrations/drop_timesheet_entry_foreign_keys_spec.rb`, three examples expected the loaded schema to still hold the three keys. A fourth asserted that the loaded schema declared them.

## Solution

- **Version checks:** parse the version out of `db/schema.rb` and require it to be at least this migration's version, not equal to it. The fixed spec does this:

  ```ruby
  schema_version = Rails.root.join("db/schema.rb").read[/define\(version: ([\d_]+)\)/, 1].delete("_").to_i
  expect(schema_version).to be >= own.version
  ```

- **Constraint or column state:** each example sets up the state it tests before running the migration. The older drop spec gained `add_dropped_keys_validated`, which adds and validates each key with `if_not_exists: true`. The examples about "a database that still has them" call it first, and their assertions stay unchanged.
- **Assertions about the loaded schema:** these belong to the spec of whichever migration currently decides that state. The old spec's "present in the loaded schema" assertion was deleted, and its example was renamed to `DROPPED_KEYS lists the three timesheet entry keys`. The new migration's spec now asserts the opposite: the loaded schema declares none of the three keys.

The same rule works in both directions. The new spec removes the keys before it tests `down` and adds them before it tests `up`. That way its examples do not depend on the loaded schema either.

## Why it matters

An example that reads the loaded schema is not testing its migration. It is testing whatever the newest migration left behind. That causes two failures:

- Each later migration breaks unrelated specs. The author must then work out which examples were only passing because of the loaded schema.
- When the loaded state matches what the migration should do, an example can pass even if the migration does nothing. For example, a restore passes because the key was already there.

When you add a migration that removes or changes something, search `spec/db/migrations` for examples that read the loaded version, keys or columns. Move each such assertion to the spec of the migration that now decides that state, and say in the pull request where it moved.

## Evidence

- PR #508, `spec/db/migrations/add_settling_to_timekeeping_ownership_spec.rb`: the exact-version `include("define(version: ...)")` assertion becomes `expect(schema_version).to be >= own.version`. A comment in the spec says later migrations move the schema version on.
- PR #508, `spec/db/migrations/drop_timesheet_entry_foreign_keys_spec.rb`: adds `add_dropped_keys_validated` and calls it first in three examples. It removes `expect(restored_dropped_keys).to eq(described_class::DROPPED_KEYS)` and renames the example to `DROPPED_KEYS lists the three timesheet entry keys`.
- PR #508, `spec/db/migrations/drop_timesheet_entry_foreign_keys_for_cutover_spec.rb`: the example `the loaded schema declares none of the three cutover keys and keeps the projects and users keys` takes over the loaded-schema check. Its `up` and `down` examples add or remove the keys before running the migration.
- PR #508, `db/schema.rb`: the version moves to `2026_11_21_120000`, and three `add_foreign_key` lines are removed.
