---
module: spec/meta
date: 2026-11-20
problem_type: convention
component: testing_framework
severity: low
audience: both
related_components:
  - database
tags:
  - test-database-guard
  - meta-spec
  - single-source-of-truth
  - database-url
applies_when:
  - A spec or helper must decide whether a database URL names a safe test database
---

# Ask TestDatabaseGuard instead of copying its `_test` rule in meta specs

## Context

The meta spec for the live handoff CI job checks that `TIMEKEEPING_DATABASE_URL` names a test database. It needs this because the handoff spec empties the Timekeeping tables after its example. A first version used its own URI rule: the last path segment must end in `_test`, and the URL may carry no `dbname=` query. The real refusal is `TestDatabaseGuard.require_test_database_url!`. A review found that the two already disagreed. With `?dbname=x_test`, the real guard accepts the URL but the copy refused it.

## Solution

Ask the guard itself, and turn its refusal into `false`:

```ruby
def test_database_url?(url)
  return false if url.to_s.empty?

  TestDatabaseGuard.require_test_database_url!(url)
  true
rescue TestDatabaseGuard::NotATestDatabase
  false
end
```

Keep the example with a `dbname=timekeeping` override. The real guard refuses it, so the example still has a case that must fail.

## Why it matters

The meta spec exists to promise that CI never points a destructive spec at a non-test database. That promise only holds if the meta spec uses the same rule as the code that does the refusing. A copied rule drifts when the guard changes, and it can pass or fail URLs the guard decides the other way.

## Evidence

- PR #477, `spec/meta/ci_spec_coverage_spec.rb`: `test_database_url?` calls `TestDatabaseGuard.require_test_database_url!` and rescues `TestDatabaseGuard::NotATestDatabase`. Its comment says the handoff spec refuses any database the shared guard does not accept. The example "fails when TIMEKEEPING_DATABASE_URL overrides its database with a dbname query" uses `?dbname=timekeeping`.
- Verification step to run, not shown in the diff: call `TestDatabaseGuard.require_test_database_url!` on a `timekeeping_live_test` URL with `?dbname=x_test` and with `?dbname=timekeeping`. The author's run of this check on PR #477 reported that the first was accepted and the second refused.
