---
module: timekeeping-handoff
date: 2026-11-14
problem_type: design_pattern
component: timekeeping_handoff
severity: high
audience: both
related_components:
  - lib/timekeeping/handoff/steps.rb
  - docs/architecture/timekeeping-soa.md
tags:
  - resumable-handoff
  - reconcile
  - flip
  - interruption
  - stale-verification
applies_when:
  - A resumable runner records a verification step and then runs a step that cannot be undone, such as moving ownership
  - A run can be interrupted after the verification is recorded and resumed later
---

# Rerun a recorded check inside the irreversible step when a resume skipped it

## Context

The Timekeeping handoff records the last finished step in `handoff_step` and resumes at the step after it. Reconcile compares the invoice operation intents saved at the checkpoint (`source_intents.json`) with a fresh read and refuses on any unexplained difference. Flip then moves ownership and admits the incoming owner.

If a run stops right after `reconcile` is recorded, the resume starts at `flip`. Before PR #253, `flip` only checked that the row said `"reconcile"`. A terminal intent deleted or edited during the interruption was never compared, and ownership moved anyway. The recorded label said the data had been checked. It did not say the data was still the same.

## Solution

Put the recheck inside the irreversible action, keyed on what this run did, not on the recorded label:

```ruby
def flip
  reconcile if @reconciliation.nil?
  update_row(expected_step: "reconcile") do |row|
```

`@reconciliation` is set only when this process ran reconcile. A fresh run pays nothing extra. A resumed run repeats the same comparison before any row write. A refusal raises before `update_row`, so the owner, generation and `handoff_step == "reconcile"` stay as they were, and a later resume checks again.

Two choices kept this small:

- Reuse the one existing comparison instead of writing an intents-only recheck. A second comparison could drift from the first. This is safe only because reconcile only reads: the saved baselines are read, never rewritten, on this path.
- Leave the pure step decision alone. Making a recorded `reconcile` resume at `reconcile` would break the rule "resume at the step after the recorded one". It would also leave a recorded label between the check and the ownership write, so an interruption could reopen the same gap one step later.

The recheck must read the saved baseline and refuse if it is missing. Capturing the current rows again would compare them with themselves and always pass.

## Why it matters

Any check-then-act pair split across two recorded steps has this gap. The check result goes stale the moment the run stops. Only the act step knows it is about to do something that cannot be undone, so that is where the check must hold. Both directions (cutover and rollback) share `flip`, so both get the recheck with no extra code.

When you add a new irreversible step after a recorded check, ask: if the run stops between them, what makes the act step re-verify? Then test an interruption at that exact point, not only at an earlier one.

## Evidence

- PR #253 adds `reconcile if @reconciliation.nil?` at the top of `flip` in `lib/timekeeping/handoff/runner.rb`, with a comment saying a resume after reconcile was recorded skips that step.
- PR #253 adds examples in `spec/lib/timekeeping/handoff/runner_legacy_handoff_spec.rb` that interrupt with `TimekeepingHandoffHooks::Interrupt.new(at: :after_reconcile)`, then delete an intent, change `desired_entry_ids`, or add an intent. Each resume raises `Runner::Refused`, keeps `handoff_step` at `"reconcile"`, and sends no admit. A rollback example shows the same refusal, then a finished rollback once the intent is restored.
- The same spec file shows a resume with `source_intents.json` deleted raises `Timekeeping::Handoff::ReportDirectory::Unreadable` instead of capturing the intents again.
- PR #253 updates the Resumable paragraph in `docs/architecture/timekeeping-soa.md` to say a resume after reconciliation was recorded runs it again before the flip.
