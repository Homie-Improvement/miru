---
module: timekeeping
date: 2026-11-20
problem_type: design_pattern
component: testing_framework
severity: medium
audience: both
related_components:
  - timekeeping_handoff
tags:
  - checkpoint-load
  - fixtures
  - admission-fence
  - retry
applies_when:
  - A spec helper arranges rows in the Timekeeping app through TimekeepingStore#load_checkpoint
  - A helper may be called more than once in one example
---

# Reload the example's union when a checkpoint load replaces whole tables

## Context

`TimekeepingStore#load_checkpoint` replaces whole tables. A fixture helper that loads only the rows of the current call deletes every row an earlier call in the same example loaded. Each call on its own looks right, so a spec that arranges twice tests a store missing its first batch.

The load is also wrapped in steps that change the live app: `fence_admission` before it (the service refuses an unfenced load), `advance_entry_id_sequence(above:)` after it (the load leaves the entries sequence alone), and `admit(generation:)` in an `ensure`.

## Solution

In `spec/support/timekeeping/owned_entries.rb`, the timekeeping writer:

- keeps the rows loaded so far in an instance variable of the example, so every example starts empty, matching the adapter's per-example database reset;
- builds each checkpoint from that union plus the new rows, and advances the sequence above the highest id in the whole union;
- stores the new union only after `load_while_fenced` returns, and records the arranged ids only after the owner write, before the projection write.

Recording late is what keeps a failed call retryable. If the load or `admit` raised, nothing was recorded, so the same batch can be sent again without a repeated-id error. If only the projection write fails, the owner rows exist and their ids are already recorded, so a retry correctly raises `ArgumentError`.

The `ensure` must not let an `admit` failure replace the load error. The helper remembers the in-flight error in a `rescue` that re-raises it, and re-raises an `admit` error only when nothing failed first.

## Why it matters

The union is invisible when a spec arranges once, which is the common case. The first spec that arranges twice would lose rows with no error. Recording state before the store confirms the write would turn a transient load failure into a confusing repeated-id error on retry.

## Evidence

- PR #473 adds `load_timekeeping_entries`, `load_while_fenced` and `restore_admission` in `spec/support/timekeeping/owned_entries.rb`.
- `spec/integration/timekeeping/owned_entries_spec.rb` checks, with an injected store, that the second load carries both batches and advances above the highest union id.
- The same spec shows a failed load records nothing: the same batch is then arranged again and returns its id.
- Further examples cover load and `admit` both failing (the load error wins) and only `admit` failing (its error propagates).
- Issue #413 states that `load_checkpoint` replaces whole tables and that a second call must not drop the first batch.
