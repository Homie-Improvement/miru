---
module: spec/support/timekeeping
date: 2026-11-19
problem_type: convention
component: testing_framework
severity: high
audience: both
related_components:
  - database
  - development_workflow
tags:
  - test-database-guard
  - database-url
  - libpq
  - active-record
  - db-prepare
applies_when:
  - A test helper spawns a process that runs migrations or deletes rows in a database named by environment variables
  - A guard checks a database name before a destructive step that a different program performs
---

# Guard the database a spawned process opens, under every way it reads the URL

## Context

The live runtime harness in `spec/support/timekeeping/integrated_runtime.rb` runs `db:prepare` and starts both apps in child processes. Before anything destructive, it refuses any database whose name does not end in `_test`. That check only protects data if it names the database the child really opens.

Two gaps make a natural guard check the wrong database:

- The launched monolith prefers a caller `DATABASE_URL` over the test process's own connection. Checking `ActiveRecord::Base.connection_db_config.database` alone lets a caller URL naming `miru_web_development` through.
- One PostgreSQL URL can name two databases. In `postgresql://user@127.0.0.1/timekeeping_development?dbname=timekeeping_selector_test`, libpq (used by the reset helper) reads the `dbname` parameter, while Active Record (used by `db:prepare` and the apps) reads the path. A libpq-only check sees a `_test` name; Rails migrates `timekeeping_development`.

## Solution

Resolve the target from the child's environment, then check it under every parser that will act on it:

```ruby
child_monolith_url = env[TimekeepingDemo::RuntimePlan::MONOLITH_DATABASE_URL].to_s
TestDatabaseGuard.require_test_database_url!(child_monolith_url) unless child_monolith_url.strip.empty?
TestDatabaseGuard.require_test_database_url!(timekeeping_database_url(env))

# spec/support/timekeeping/timekeeping_database_reset.rb
module TestDatabaseGuard
  def require_test_database_url!(url)
    require_test_database!(TimekeepingDatabaseReset.database_name(url))
    require_test_database!(active_record_database_name(url))
  end
end
```

The guard lives in `TestDatabaseGuard`, so every helper that hands a URL to a spawned process (`IntegratedRuntime.start` and the collector probe today) applies the same two readings. `active_record_database_name` builds an `ActiveRecord::DatabaseConfigurations::UrlConfig` without connecting. Run all of these checks before the first spawn, because a pending migration cannot be undone once `db:prepare` starts.

## Why it matters

A guard that reads a different database than the destructive step is worse than none, because it looks like protection. The rule holds for any pair of programs that parse one connection string: check the reading of each program that writes, not the reading of the program that does the checking. This change shows the libpq and Active Record disagreement for PostgreSQL URLs; other adapters were not examined.

## Evidence

- PR #378 adds `require_test_database_url!`, `active_record_database_name` and the caller `DATABASE_URL` check to `IntegratedRuntime.start` in `spec/support/timekeeping/integrated_runtime.rb`. Both methods later moved, unchanged, to `TestDatabaseGuard` in `spec/support/timekeeping/timekeeping_database_reset.rb`; `spec/meta/test_database_guard_spec.rb` pins them there.
- `spec/lib/timekeeping_demo/integrated_runtime_spec.rb` adds "start refuses a Timekeeping URL whose path names a non-test database behind a _test dbname parameter". Its comment states that libpq reads the parameter and Rails reads the path, and it expects `NotATestDatabase` naming `timekeeping_development` with no spawn and no reset.
- The same spec adds "start refuses a caller DATABASE_URL naming a non-test monolith database before anything is spawned", which expects a refusal naming `miru_web_development`.
- `spec/support/timekeeping/timekeeping_database_reset.rb` drops `database_name` from its private methods in this change so the harness can reuse the libpq reading.
