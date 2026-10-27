---
module: Timekeeping::Handoff::Runner
date: 2026-10-27
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: speculative
audience: both
related_components:
  - Timekeeping::Handoff::LegacyOperationsCheck
  - InvoiceOperationsRecord
tags:
  - timekeeping-handoff
  - legacy-cutover
  - completion-check
  - observer
  - rspec
applies_when:
  - Writing a runner spec where the legacy drain check (drained?) must stay false while settle (settled?) passes
  - A handoff spec plants rows on InvoiceOperationsRecord.connection to block a specific step
---

# Plant a legacy drain blocker only after settle passes, from an observer

## Context

On a first cutover the source is legacy, so the owners carry `settle: nil, drain: nil`. Then `LegacyOperationsCheck` answers both completion checks: `settled?` for the settle step and `drained?` for the freeze step. The spec comment in this change states that both answers come from the same query over unfinished invoice operations.

That means a `prepared` row in `invoice_operations` blocks settle just as well as it blocks drain. If a spec inserts it before calling `Runner.run`, the run refuses at settle. The spec still sees `Runner::Refused`, so it looks green, but it never reaches the drain check it claims to test.

## Solution

Insert the drain blocker from an `observer:` callback, on the `:after_step` event for the `settle` step:

```ruby
prepare_after_settle = lambda do |event, step:|
  next unless event == :after_step && step.to_s == "settle"

  connection.execute(<<~SQL.squish)
    INSERT INTO invoice_operations (...) VALUES (..., 'prepared', 'active', 2, now())
  SQL
end

described_class.run(direction: :cutover, owners:, report_root:, clock:, observer: prepare_after_settle)
```

Then assert the exact step the refusal left behind. A drain refusal leaves `handoff_step` at `"settle"`. A settle refusal leaves it at `"close_admission"`. Checking `[generation, owner, handoff_step]` against `[2, "monolith", "settle"]` is what proves the spec hit drain and not settle.

To block settle instead, insert a `pending` row into `invoice_operation_intents` before the run. Expect `"close_admission"`.

Delete the planted row in an `ensure` block on `InvoiceOperationsRecord.connection`. The spec comment notes that the suite's cleanup hook does not delete `invoice_operations`, and a leftover `prepared` row makes `MonolithStore#export_checkpoint` refuse in later examples.

## Why it matters

Without this, a drain-incomplete spec for the legacy path silently tests settle twice. A later edit that broke the drain guard would pass the suite. Asserting `Refused` alone cannot catch this, because both steps raise the same error. Only the recorded `handoff_step` tells the two apart.

## Evidence

- PR #243 adds `spec/lib/timekeeping/handoff/runner_incomplete_checks_spec.rb`. Its group "legacy drain left incomplete by a prepared operation" builds the `prepare_after_settle` observer shown above. The comment above it says the legacy check answers `settled?` and `drained?` with the same query, so a row inserted earlier would fail settle instead of drain.
- The same group expects the refused run to leave `[2, "monolith", "settle"]`. The group "legacy settle left incomplete by a pending intent" expects `[2, "monolith", "close_admission"]`.
- The `ensure` block in the drain group deletes the planted row, with a comment that the cleanup hook skips `invoice_operations` and a leftover row breaks `MonolithStore#export_checkpoint`.
- The PR body reports that with the completion-check raise removed from `Runner#carry_out`, all 4 new examples failed.
- The shared query inside `LegacyOperationsCheck` is not part of this change. This document relies on the spec comment for it, so it is graded speculative. Verification step: read `LegacyOperationsCheck#settled?` and `#drained?` and confirm they read the same rows.
