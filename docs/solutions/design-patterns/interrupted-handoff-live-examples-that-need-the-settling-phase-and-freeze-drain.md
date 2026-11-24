---
module: timekeeping
date: 2026-11-24
problem_type: design_pattern
component: testing_framework
severity: medium
audience: both
related_components:
  - development_workflow
tags:
  - live-specs
  - timekeeping-live
  - handoff
  - mutation-check
applies_when:
  - You change the freeze step's relay drain or the settle step's commit and abort gate
  - You want to know which live interrupted-handoff examples would catch that change
---

# Which interrupted-handoff live examples need the freeze drain and the settling phase

## Context

`spec/integration/timekeeping/interrupted_handoff_spec.rb` proves that a handoff interrupted with relay snapshots queued can be resumed or aborted safely. Two mechanisms are meant to carry that proof:

- The freeze drain. `Runner#freeze` in `lib/timekeeping/handoff/runner.rb` calls `drain_integration.drain!(through: @final_outbox_position)`, and the freeze step completes only when `drained?` is true.
- The settling phase. During the settle step, `WriteSteps.settling_generation` in `app/services/timekeeping/local_owner/write_steps.rb` lets the outgoing owner still apply commits and aborts stored at the settling generation, and refuses everything else.

A green suite says nothing about which examples depend on either one. Removing each mechanism once and running the file shows which examples fail without it. Those runs are recorded below. Each removal was a temporary edit, reverted after the run.

The abort wait is already in place. `Runner.run(abort: true)` waits for the drain instead of raising `Refused`: `abort_handoff` calls `carry_out(owed, wait_until_complete: true)`, which sleeps `ABORT_POLL_INTERVAL` until each owed step completes. `spec/lib/timekeeping/handoff/runner_abort_wait_spec.rb` and the paused-abort groups of the interrupted-handoff spec assert it.

## The runs

Every run used `TIMEKEEPING_LIVE=1`, a Timekeeping database whose role differs from the monolith's, and this command:

```
DB_HOST=127.0.0.1 DB_USER=postgres TIMEKEEPING_LIVE=1 SKIP_VITE_TEST_BUILD=1 \
  TIMEKEEPING_DATABASE_URL=<timekeeping database url> \
  bundle exec rspec spec/integration/timekeeping/interrupted_handoff_spec.rb
```

**Unchanged code, 2026-11-24 00:44 UTC: 11 examples, 2 failures.** Both also fail in the two runs below, so neither one tells you anything about a removal:

- `:27` "resume after a before_freeze interrupt applies each queued snapshot exactly once, reconciles and keeps money, and a second resume changes nothing" fails with "projection rows of company 1 differ from the outgoing store".
- `:1083` "after a resumed rollback flips, a same-key replay gets its stored 200 and a fresh-key previous-generation batch gets 409 stale_generation, changing no projection row or receipt" fails at spec line 1097 with `TypeError: no implicit conversion of Hash into String` from `JSON.parse(accepted.fetch(:batch))`.

Nobody has checked yet whether these two fail on the base branch in CI or only in this local setup.

**Freeze drain removed, 2026-11-24 01:12 UTC: 11 examples, 9 failures.** The edit deleted the `drain_integration.drain!` call from `Runner#freeze` and made `drained?` return `true`. Besides `:27` and `:1083`, seven examples failed:

- `:133` "abort while the relay is paused keeps the row fenced, then returns the prior owner with money unchanged on each company": `expect(polls).to be >= 2`, got 0.
- `:274` "a rollback interrupted at before_freeze with snapshots queued resumes, applying each queued snapshot exactly once with reconciliation passing": `Runner::Refused`, "Reconciliation found unexplained differences".
- `:373` "a rollback reaches during_checkpoint only with the queue empty and the projection holding each queued snapshot": the paused run was expected to raise `Runner::Refused` and did not.
- `:484` "an abort while the relay is paused holds the row and admission, then completes once the relay resumes, delivering queued snapshots before the prior owner readmits": `expect(polls.size).to be >= 2`, got 0.
- `:614` "an abort started while the relay is paused, after a paused resume stored P, keeps the ownership row byte-identical and billing writes refused on every paused poll": `expect(paused_rows.size).to be >= 2`, got 0.
- `:705` "the before_freeze abort admits the outgoing owner only once every queued entry is already in the projection": `expect(polls).to be >= 2`, got 0.
- `:947` "an abort after a during_checkpoint interrupt returns the prior owner at once, with reconciliation passing and money unchanged on each company": the paused run was expected to raise `Runner::Refused` and did not.

`:791` (queue at before_freeze) and `:876` (second resume) still passed.

**Settling phase removed, 2026-11-24 01:32 UTC: 11 examples, 2 failures.** The edit made `WriteSteps.settling_generation` return `nil` on its first line, so the outgoing owner applies no commit or abort during the settle step. Only `:27` and `:1083` failed, the same two as on unchanged code. No example in this file detects the removal.

## Why it matters

The freeze drain is well guarded: seven examples fail without it, across resume, abort and interrupt paths. The settling phase is not guarded by this file at all: with the gate gone, every example gives the same result as on unchanged code. Why no example needs it was not traced. A change that breaks the settling gate must be caught somewhere else. Check that before you rely on this file for it.

## Evidence

- The three runs above, against `spec/integration/timekeeping/interrupted_handoff_spec.rb` with the inline-queue hook in place. Each removal was reverted, and `git diff` on `lib/` and `app/` was empty afterwards.
- `lib/timekeeping/handoff/runner.rb`: `freeze`, `drained?`, `abort_handoff`, `carry_out`.
- `app/services/timekeeping/local_owner/write_steps.rb`: `settling_generation`.
