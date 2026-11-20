---
module: timekeeping handoff specs
date: 2026-11-20
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - timekeeping handoff runner
tags:
  - rspec
  - seeded-without-transaction
  - two-tenant-seed
  - cutover
  - test-isolation
applies_when:
  - Adding a runner example that commits a cutover under :two_tenant_seed and :seeded_without_transaction
---

# Give each committing cutover example its own seeded-without-transaction group

## Context

A group tagged `:seeded_without_transaction` loads the two-tenant seed once. It keeps all writes between its examples, including the ownership state. After one example commits a cutover, Timekeeping owns the data and the legacy source is retired. A second cutover in the same group then defaults to resuming: it takes the readmit path, loads nothing and writes no snapshots. Its snapshot assertions fail whichever order the examples run in, or the checks never run against a real first cutover.

## Solution

Put each example that commits a cutover in its own `RSpec.describe Timekeeping::Handoff::Runner, :two_tenant_seed, :seeded_without_transaction` group, so each one starts from a fresh seed. Add a comment saying why the groups are split, so no one merges them back. Before you trust a new pair of examples, run them together in one file.

## Why it matters

Each example passes when run alone, so the problem stays hidden until the whole file runs. A shared group can also turn a "first cutover" example into a readmit example without any error message.

## Evidence

- PR #460, `spec/lib/timekeeping/handoff/runner_legacy_handoff_spec.rb`: the comment above the new raised-snapshot groups says each example commits a cutover and so needs its own group. Each of the new cutover examples sits in a separate describe group.
- PR #460 review: running `spec/lib/timekeeping/handoff/legacy_load_versions_spec.rb`, `spec/lib/timekeeping/handoff/runner_spec.rb` and `spec/lib/timekeeping/handoff/runner_legacy_handoff_spec.rb` together gave 48 examples, 0 failures after the split.
