---
module: Timekeeping test support
date: 2026-11-19
problem_type: convention
component: testing_framework
severity: low
audience: both
related_components:
  - TestDatabaseGuard
  - rails_helper
tags:
  - rspec
  - rails-helper
  - no-database
  - maintain-test-schema
applies_when:
  - A spec must run with no database connection, such as a spec of a URL parser or guard
---

# Skip rails_helper in specs that must run without a database

## Context

`spec/meta/test_database_guard_spec.rb` had to run with no database connection, because the guard only parses URLs. Loading `rails_helper` breaks that. With an unreachable database, the run stopped with `ActiveRecord::DatabaseConnectionError` from `ActiveRecord::Migration.maintain_test_schema!`: 0 examples ran and 1 error occurred outside of examples. On a machine with PostgreSQL running, the same spec passes, so the hidden connection is easy to miss.

## Solution

Require only what the code under test needs:

```ruby
require "active_record"
require "active_record/database_configurations"
require_relative "../support/timekeeping/timekeeping_database_reset"
```

Keep assertions that need the full app (for example, what `IntegratedRuntime` still defines) in a spec that already loads `rails_helper`.

To prove the spec needs no database, run it against a URL nothing listens on:

```
RAILS_ENV=test DATABASE_URL=postgresql://127.0.0.1:1/guard_no_connection_test bundle exec rspec spec/meta/test_database_guard_spec.rb
```

## Why it matters

A spec that claims to need no database but loads `rails_helper` also runs the schema check and the cleaner hooks. It fails wherever no database is reachable, and the failure points at schema setup, not at the code being tested.

## Evidence

- PR #421 adds `spec/meta/test_database_guard_spec.rb` with the three requires above and no `rails_helper`, and a comment saying `rails_helper`'s schema check and cleaners need a live database.
- Running the command above before the fix returned `ActiveRecord::DatabaseConnectionError` from `ActiveRecord::Migration.maintain_test_schema!` with 0 examples; after the fix it returned 5 examples, 0 failures.
- The check that `IntegratedRuntime` no longer defines the guard stays in `spec/lib/timekeeping_demo/integrated_runtime_spec.rb`, which loads the app.
