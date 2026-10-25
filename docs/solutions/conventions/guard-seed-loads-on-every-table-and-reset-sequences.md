---
module: timekeeping
date: 2026-10-25
problem_type: convention
component: testing_framework
severity: high
evidence_grounding: anchored
grounding_evidence: lib/timekeeping/seed_disposition_recorder.rb load_fresh_seed! refuses when any table outside METADATA_TABLES has rows, then calls reset_pk_sequence! per table; spec/lib/timekeeping/seed_disposition_recorder_spec.rb proves a lone user with no company is refused and left unchanged
audience: both
related_components:
  - seeds
  - rake_tasks
  - database
tags:
  - seeds
  - fixtures
  - reproducibility
  - empty-database-guard
  - pk-sequence
  - before-all
applies_when:
  - Loading db/seeds.rb from a rake task, a recorder or a spec, where the result is checked in or compared exactly
  - Writing a guard meant to stop a seed from running over existing data
  - Loading seed data once per example group in before(:all)
---

# Guard seed loads on every table, and reset id sequences first

## Context

PR #43 added a rake task, `timekeeping:record_seed_disposition`. It loads the demo seed and checks in a YAML record of what the seed produced. A spec then compares that record exactly against a fresh load. The comparison only means something if every load starts from the same state.

The first design checked only that the `companies` table was empty. Reviewers flagged that gap several times, because "no companies" does not mean "no data":

- A user can exist with no company.
- The seed finds users by email and rewrites their name, password and workspace. A leftover account with a seed email gets overwritten silently, even in a development database.
- Which entries the seed creates depends on user ids. Leftover rows, or id sequences that have already moved forward, change the seeded entry ids. The recorded file then stops matching a fresh load.
- A reseed also destroys and recreates invoice line items, which changes lock state.

## Solution

Define "empty" as every application table having no rows. Exclude only Rails' own bookkeeping tables. Check this before you touch anything. Then reset the id sequences so that two loads give the same ids:

```ruby
METADATA_TABLES = %w[ar_internal_metadata schema_migrations].freeze

def load_fresh_seed!(as_of:)
  tables = application_tables
  occupied = tables.select { |table| table_has_rows?(table) }
  if occupied.any?
    raise Error, "Refusing to load the seed over existing data in: #{occupied.sort.join(', ')}"
  end

  tables.each { |table| connection.reset_pk_sequence!(table) }
  with_seed_as_of(as_of) { load SEED_PATH.to_s }
end
```

Three related rules come from the same change:

1. **Keep loading and writing as separate steps.** `generate!` is `load_fresh_seed!` followed by `write!`, and `write!` never loads the seed. A spec that has already loaded the seed calls `write!` directly. That way the spec never needs to weaken the guard to pass.
2. **Pin every input the seed reads.** The loader sets `MIRU_SEED_AS_OF` for the duration of the load and restores the old value afterwards. The checked-in file stores that `as_of`, and the spec reloads with it.
3. **Truncate around a load that runs once per group.** A `before(:all)` load runs outside the transaction that wraps each example. So the shared context truncates every table before the load and again in `after(:all)`. Without that, two seeded tenants would leak into later specs.

## Why it matters

A guard that checks only the tenant table looks right and passes its obvious test. Its failures are quiet: an overwritten developer account, or a checked-in record that no fresh load can reproduce. Checking every table costs one cheap `SELECT 1 ... LIMIT 1` per table. Resetting sequences is what makes a byte-identical regeneration possible at all.

The test that proves the guard needs a state the guard could miss: a lone user with a seed email and no company. A test with a company row alone does not show the gap.

## Evidence

PR #43, head commit 3a41b7a69f93df3b4ed1e1caf33585e24d841771.

- `lib/timekeeping/seed_disposition_recorder.rb`: `load_fresh_seed!` checks every table in `connection.tables - METADATA_TABLES`, raises before any change, and then calls `reset_pk_sequence!` for each table. Its comment says the seed finds users by email and rewrites them, and that the seeded entries depend on user ids. `generate!` calls `load_fresh_seed!` and then `write!`, and `write!` does no load.
- `spec/lib/timekeeping/seed_disposition_recorder_spec.rb`: "refuses a database holding only a user with no company, and leaves that user unchanged" deletes all companies, expects an error that names `users`, and checks the user's name, encrypted password and workspace are unchanged.
- `spec/tasks/timekeeping_rake_spec.rb`: the rake task refuses the same lone-user database, prints "Refusing to load the seed over existing data", and writes no file.
- `spec/support/two_tenant_seed.rb`: `before(:all)` runs `DatabaseCleaner.clean_with :truncation` before `load_fresh_seed!`, and `after(:all)` truncates again.
- `spec/timekeeping/seed_disposition_spec.rb`: "writes, from the loaded seed, a file identical to the checked-in one" calls `write!`, not `generate!`, on the load that already exists.
