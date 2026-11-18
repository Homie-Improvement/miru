---
module: Timekeeping test harness
date: 2026-11-18
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - RSpec
  - PostgreSQL
  - Open3
tags:
  - subprocess
  - test-isolation
  - database-cleaner
  - transactions
applies_when:
  - An RSpec example waits for a child spec process whose cleaners use the parent's test database.
---
# Run shared-database subprocess probes outside parent transactions

## Context

A child spec process does not necessarily have a separate database. The Timekeeping probes override `TIMEKEEPING_OWNER_STATE`, while other environment settings remain inherited.

A parent transaction can hold a database lock that the child's cleaner needs. Meanwhile, `Open3.capture3` waits for the child to exit. The parent cannot finish its example and release the transaction until that wait ends.

## Solution

Use the repository's `:without_transaction` mode on the **parent example group** that launches the probe. Changing only the child's transaction mode does not release locks held by the parent.

PR #373 uses this arrangement for ownership probes:

```ruby
RSpec.describe "TIMEKEEPING_OWNER_STATE probe run", :without_transaction do
```

The parent launches `bundle exec rspec` through `Open3.capture3`. The child deliberately runs a `committed_data` example before checking the ownership row. That sequence exercises the real cleaner rather than substituting a mocked reset.

When adding another subprocess probe, check which database settings it inherits before choosing the parent's transaction mode. A new process separates Ruby state, not database locks.

## Why it matters

An isolated subprocess is useful for testing load-time environment selection. It does not remove the need to coordinate database access between processes.

Without this distinction, a probe can stop making progress before it reaches its assertions. Increasing a timeout does not remove the dependency between the waiting parent and the blocked child.

## Evidence

PR #373 adds parent probe groups tagged `:without_transaction` in `spec/meta/timekeeping_owner_state_spec.rb`. Those groups synchronously launch child specs with `Open3.capture3` and environment overrides for `TIMEKEEPING_OWNER_STATE`.

The added `spec/fixtures/timekeeping_harness/owner_state_probe.rb` uses `order: :defined`. Its first example has `committed_data: true`; its second checks ownership after that example's cleanup. Together, these files show the parent transaction choice paired with a child that exercises database cleaning.
