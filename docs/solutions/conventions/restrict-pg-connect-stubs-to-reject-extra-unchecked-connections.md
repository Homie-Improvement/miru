---
module: Timekeeping regression helpers
date: 2026-11-24
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - TimekeepingRegressionAdapter
  - forwarded Timekeeping helpers
tags:
  - rspec
  - database-url
  - test-doubles
applies_when:
  - Testing that live Timekeeping helpers connect only to the checked test database
  - Checking connection arguments with have_received and an exact matching-call count
---

# Reject extra unchecked connections in database-URL tests

## Context

A helper must use only the database URL checked by the live Timekeeping adapter. Proving one correct connection is not enough.

This combination leaves a gap:

```ruby
allow(PG).to receive(:connect).and_return(connection)
expect(PG).to have_received(:connect).with(reader_checked_database_url).once
```

The assertion counts calls that match its argument. It does not count all calls to `PG.connect`. An additional `PG.connect(nil)` can therefore coexist with the one matching call without failing this assertion.

## Solution

Reject unexpected arguments at the connection stub:

```ruby
allow(PG).to receive(:connect)
  .with(reader_checked_database_url).and_return(connection)
```

Keep the matching `have_received(...).once` assertion after the helper runs. The constrained stub rejects other URLs. The assertion requires exactly one connection with the permitted URL.

Verify both kinds of failure separately. Replace the correct URL with nil or another URL. Then restore it and add an extra `PG.connect(nil)` before the correct connection. The extra-call case checks a gap that replacement alone does not expose.

## Why it matters

A database-safety test must reject every unchecked connection, not merely observe one checked connection. A broad stub hides additional attempts even when the final assertion uses `.once`.

Apply this rule where the contract permits only one checked database target. Tests that intentionally open several targets need explicit expectations for those targets instead.

## Evidence

PR #626 restricts both live-helper `PG.connect` stubs in `spec/contracts/timekeeping/forwarded_timekeeping_helpers_spec.rb` to `reader_checked_database_url`. Both examples also assert `have_received(:connect).with(reader_checked_database_url).once`.

The recorded verification for PR #626 tested an extra `PG.connect(nil)`, a nil replacement, and another URL replacement. Each change made both live-helper examples fail with unexpected arguments. The helper implementation was restored after each check.
