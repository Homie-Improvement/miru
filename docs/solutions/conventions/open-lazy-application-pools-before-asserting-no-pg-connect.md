---
module: spec/db
date: 2026-11-19
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - database
tags:
  - pg-connect
  - connection-pool
  - order-dependent-test
  - invoice-operations-record
applies_when:
  - A spec asserts PG.connect is not called while code under test writes through application models
---

# Open lazy application pools before asserting no PG.connect

## Context

Some specs prove that no Timekeeping database connection opens by watching `PG.connect`. The seeded reset first loads the seed. The seed writes invoices through `InvoiceOperationsRecord`, which has its own connection pool. That pool opens its first connection lazily. If nothing has opened it yet, the seed calls `PG.connect`, and the assertion fails even though the Timekeeping guard worked.

## Solution

Before setting up the `PG.connect` spy, open every application pool the code path can use:

```ruby
[ActiveRecord::Base, InvoiceOperationsRecord].each { |model| model.connection_pool.with_connection(&:verify!) }
expect(PG).not_to receive(:connect)
```

Then any connection that still opens comes from the code you mean to watch. Run the example alone with `-e` to confirm it does not rely on an earlier example having opened a pool.

## Why it matters

In a full run, an earlier example has usually opened the pool already, so the spec passes. It fails only when run alone or first in its process. That kind of failure is hard to trace back to the cause, and people may delete or loosen the assertion instead of fixing it.

## Evidence

- PR #381, `spec/db/committed_data_mode_spec.rb`: three seeded-reset examples open both pools before they watch `PG.connect`. A comment explains that the seed writes through `InvoiceOperationsRecord`'s lazily opened pool.
- Build review on PR #381 found that the refusal example lacked this step. After the fix, the author ran `SPEC_OPTS= bundle exec rspec spec/db/committed_data_mode_spec.rb -e "refuses a non-test Timekeeping database"`, which ran that example alone and first in its process, with result 1 example, 0 failures.
