---
module: spec_support
date: 2026-10-26
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: anchored
grounding_evidence: spec/support/database_cleaner.rb adds :seeded_without_transaction to outside_transaction with a comment on why; spec/lib/timekeeping/handoff/legacy_source_spec.rb puts read-only examples in one :two_tenant_seed, :seeded_without_transaction group and each row-writing example in its own group
audience: both
related_components:
  - database_cleaner
  - two_tenant_seed
tags:
  - rspec
  - database-cleaner
  - repeatable-read
  - seed-fixtures
  - transaction-isolation
applies_when:
  - A spec uses :two_tenant_seed and the code under test opens a transaction with an isolation level
  - Adding a new example to a :seeded_without_transaction group
---

# Use :seeded_without_transaction for seed specs that open real transactions

## Context

Some code opens its own transaction with an isolation level, for example `connection.transaction(isolation: :repeatable_read)` in `Timekeeping::Handoff::LegacySource#export`. Rails refuses to set an isolation level inside an open transaction and raises `ActiveRecord::TransactionIsolationError`.

Two existing spec setups each break this in a different way:

- The default setup wraps every example in a transaction, so the isolation call raises.
- `:without_transaction` runs outside that transaction, but it truncates every table before each example. That deletes the `:two_tenant_seed` data, which the group loads only once.

## Solution

Tag the group `:two_tenant_seed, :seeded_without_transaction`. The new tag runs examples outside the per-example transaction and does not truncate between examples. The seed group's own truncation still cleans up when the group ends.

The tag has one cost: examples share the seed with no rollback. So:

- Put examples that only read in one shared group, so the large seed loads once.
- Give every example that writes rows (`update_columns`, `Audited::Audit.create!`, a new duplicate entry) its own top-level `RSpec.describe` with both tags, so the next group reloads a clean seed.
- Build faults in memory where you can (for example, change the recorded disposition hash) so the example stays read-only.

## Why it matters

With the wrong tag, the spec fails in setup or finds an empty database, and never reaches the code under test. With the right tag but a writing example in the shared group, later examples see a changed seed and fail or pass for the wrong reason, depending on run order.

## Evidence

- PR #90, head commit d2ca3d1191f4fa42215e4ab2cd416f757189d62a.
- `spec/support/database_cleaner.rb`: `outside_transaction` now also matches `example.metadata[:seeded_without_transaction]`. The comment says these examples are not truncated so the seed survives, and that an example that writes rows needs a group of its own.
- `spec/lib/timekeeping/handoff/legacy_source_spec.rb`: the first group holds read-only examples, with a comment that the seed is loaded once for all of them. The discarded-invoice, company-mismatch, orphan and audit examples each sit in their own group. The example "refuses an export started inside a caller's open transaction and exports outside one" expects `ActiveRecord::TransactionIsolationError` inside a transaction.
