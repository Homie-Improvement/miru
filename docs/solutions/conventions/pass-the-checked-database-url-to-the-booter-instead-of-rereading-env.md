---
module: Timekeeping live specs
date: 2026-11-19
problem_type: convention
component: testing_framework
severity: high
audience: both
related_components:
  - TimekeepingLiveInstance
  - TestDatabaseGuard
tags:
  - timekeeping
  - database-url
  - child-process-env
  - test-database-guard
applies_when:
  - A spec or harness checks a database URL and then starts processes that run db:prepare or a server
  - A booter reads TIMEKEEPING_DATABASE_URL from global ENV while its caller checked a URL from somewhere else
---

# Pass the checked database URL to the booter instead of rereading ENV

## Context

The check that refuses a non-test database only protects you if the database it checked is the one the child processes open. `TimekeepingLiveInstance` used to build its child env from `ENV.fetch("TIMEKEEPING_DATABASE_URL")`. A caller that checked a URL from an injected env hash could then watch `db:prepare` open a different database that nobody checked. Once `db:prepare` starts, its migrations cannot be undone.

## Solution

Let the caller pass the URL it checked, and make that value the only URL every child gets:

```ruby
TimekeepingLiveInstance.start(reference_stub:, admission_generation: 2, port:, database_url:)
```

Inside the instance, fall back to the global variable only when the argument is `nil`:

```ruby
def database_url
  return @database_url unless @database_url.nil?

  ENV.fetch("TIMEKEEPING_DATABASE_URL") do
    raise BootError, "TIMEKEEPING_DATABASE_URL must name the live Timekeeping test database"
  end
end
```

Use `nil?`, not truthiness or `presence`. With `presence`, a blank `database_url: ""` would fall back to the global URL, which is exactly the unchecked database this keyword exists to avoid. A blank value passed through is refused by the caller's `TestDatabaseGuard.require_test_database_url!`, because neither reading of a blank URL ends in `_test`.

Build one env hash (`service_env`) and use it for every child: `db:prepare`, the admit runner and the spawned server. Test all of them, not only `db:prepare`.

## Why it matters

A guard and a later read of the same setting are two separate facts that can disagree. Passing the checked value makes the URL a single fact. The instance itself still does not run the guard; it trusts its caller. A caller that skips the check gets no protection, so any new caller must call `TestDatabaseGuard.require_test_database_url!` on the value it passes.

## Evidence

- PR #421 changes `spec/support/timekeeping/live_instance.rb`: `service_env` now reads `"TIMEKEEPING_DATABASE_URL" => database_url`, and the new private `database_url` method returns `@database_url unless @database_url.nil?`.
- `spec/meta/timekeeping_live_instance_spec.rb` stubs global ENV to one URL, passes another as `database_url:`, and checks that every captured child env (from `Open3.capture2e` and `Process.spawn`) carries only the injected URL and `"DATABASE_URL" => nil`. Another example passes `database_url: ""` and checks that the `db:prepare` env carries `""`, not the global URL.
- `spec/integration/timekeeping/live_instance_generation_spec.rb` checks its URL with `TestDatabaseGuard.require_test_database_url!` and passes that same value as `database_url:`.
