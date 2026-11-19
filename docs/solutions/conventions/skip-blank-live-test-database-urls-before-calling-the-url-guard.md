---
module: Timekeeping live specs
date: 2026-11-19
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - TestDatabaseGuard
  - TimekeepingLiveInstance
tags:
  - timekeeping
  - live-tests
  - database-url
  - skip-conditions
applies_when:
  - Adding an optional live spec that checks TIMEKEEPING_DATABASE_URL with TestDatabaseGuard
---

# Skip blank live-test database URLs before calling the URL guard

## Context

An optional live spec must skip when its database setting is absent. It must not fail during setup.

`TestDatabaseGuard.require_test_database_url!` checks database names through two parsers. Its named refusal, `NotATestDatabase`, does not cover every invalid input. Verification with `nil` raised `TypeError`. Rescuing only `NotATestDatabase` therefore did not implement the required skip.

## Solution

Check whether the setting exists before asking the guard to validate its database names. Keep configuration absence separate from URL refusal:

```ruby
database_url = ENV.fetch("TIMEKEEPING_DATABASE_URL", "")
skip "Set TIMEKEEPING_DATABASE_URL to the live Timekeeping test database" if database_url.strip.empty?

begin
  TestDatabaseGuard.require_test_database_url!(database_url)
rescue TestDatabaseGuard::NotATestDatabase
  skip "Set TIMEKEEPING_DATABASE_URL to a URL whose libpq and Active Record names both end in _test"
end
```

Do not replace this check with a broader rescue. Other setup errors should still fail the spec. This guidance concerns optional live-test configuration; it does not change the shared guard's exception contract.

## Why it matters

The guard can refuse a parsed database name without accepting every Ruby value as a URL. A caller must not infer a uniform exception contract from the guard's purpose.

A direct blank check gives missing configuration its intended outcome without hiding unrelated failures.

## Evidence

PR #421 adds the blank check before the guard in `spec/integration/timekeeping/live_instance_generation_spec.rb`. It also passes the checked value to `TimekeepingLiveInstance.start` as `database_url:`.

Verification for this pull request called `TestDatabaseGuard.require_test_database_url!(nil)` through a Rails runner and observed `TypeError`. After the fix, running the live spec with `TIMEKEEPING_LIVE=1` and no `TIMEKEEPING_DATABASE_URL` skipped with the stated database-setting reason.

The relocation in `spec/support/timekeeping/timekeeping_database_reset.rb` preserves the two-reading guard rather than adding missing-configuration handling to it.
