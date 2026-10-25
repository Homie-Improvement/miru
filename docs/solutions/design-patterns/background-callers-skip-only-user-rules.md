---
module: gems/timekeeping_rules
date: 2026-10-25
problem_type: design_pattern
component: authorization_rules
severity: high
evidence_grounding: anchored
grounding_evidence: In gems/timekeeping_rules/lib/timekeeping_rules/entry_rules.rb, CHANGE_RULES makes :a2 bind every caller while :a3, :a4, :a6 and :a7 bind only user-delegated callers, and check_caller! raises UnknownCaller for anything outside USER_DELEGATED and BACKGROUND_OPERATIONS; caller_spec.rb and change_decision_spec.rb pin both.
audience: both
related_components:
  - timesheet_entries
  - background_jobs
tags:
  - authorization
  - background-caller
  - billed-entries
  - allowlist
  - timekeeping
applies_when:
  - Moving timesheet entry rules out of the monolith, where the model skips checks when Current.user is nil
  - Adding a background operation that changes, deletes or moves entries
  - Designing any rule set where system callers bypass some user checks
---

# Background callers skip only the rules that depend on a user

## Context

Today the timesheet entry model skips its locked-entry and away-from-billed checks whenever `Current.user` is nil. Any code path without a user gets the skip, on purpose or by accident.

When these rules moved into the pure gem `TimekeepingRules::EntryRules`, the first design gave every background caller a full pass over the change rules. Review showed what that meant: a background delete, or a bulk move, of a billed entry would return `:ok`. A billed entry backs an invoice, so this would let a job erase or move invoiced time.

## Solution

Sort each rule by what it protects:

- **Rules about the user** (A3 edit window, A4 own entries only, A6 locked entry, A7 away from billed) read the caller's role and id. A background job has neither, so these rules bind user-delegated callers only. That is the background skip.
- **Rules about the record** (A2: a billed entry is never updated or deleted) bind every caller, background jobs included, in both the single and the bulk decision.

The gem writes this as data. Each row of `CHANGE_RULES` is `[rule id, binds, refuses]`; the `binds` lambda for `:a2` is always true, and the others require `facts[:user_delegated]`.

Grant the skip by name, never by absence. `caller:` must be `:user_delegated` or one of the strings in `BACKGROUND_OPERATIONS`, such as `"reservations.commit"`. Anything else raises `UnknownCaller`, which is an `ArgumentError`. That covers `nil`, the string `"user_delegated"`, the symbol `:"reservations.commit"` and a misspelling. A missing caller fails loudly instead of being read as a background job.

One result follows: a background change away from billed still returns `:forbidden`. A2 refuses it, so the A7 skip is visible only through `refusing_rules`, which returns `[:a2]` instead of `[:a2, :a7]`.

## Why it matters

The monolith will switch to this gem later. Whoever wires it in will be tempted to map "no current user" to a background caller, which brings back the nil-means-skip hole. Pass the named operation instead.

When you add a rule, decide which group it belongs to. If it protects the data whoever acts, it binds every caller. If you add a background operation, add its exact name to `BACKGROUND_OPERATIONS`; do not loosen the check.

## Evidence

- PR #36, head commit 4319394465d3f3cae6ab3cc37c8f77449ae84fe2.
- `gems/timekeeping_rules/lib/timekeeping_rules/entry_rules.rb`: `CHANGE_RULES`, `BACKGROUND_OPERATIONS`, `check_caller!` and `change_facts`, where `privileged` and `employee` are false unless the caller is user-delegated.
- `gems/timekeeping_rules/spec/timekeeping_rules/entry_rules/caller_spec.rb`: `nil`, `:agent`, `"user_delegated"`, `:"reservations.commit"`, `"reservations.comit"` and `false` raise `UnknownCaller` from `change_decision`, `refusing_rules` and `bulk_decision`, even with no entries.
- `gems/timekeeping_rules/spec/timekeeping_rules/entry_rules/change_decision_spec.rb`: a background caller (`"agents.detach_entries"`) updating or deleting a billed entry gets `:forbidden`; `"invoices.mark_billed"` changing billed to unbilled gets `refusing_rules == [:a2]`; `"entries.import"` on a locked, stale, foreign, unbilled entry gets `:ok`.
- `gems/timekeeping_rules/spec/timekeeping_rules/entry_rules/bulk_decision_spec.rb`: a background bulk move or delete that includes a billed entry gets `:forbidden`.
- The PR body states that the A7 background skip shows only in `refusing_rules` and that `change_decision` stays `:forbidden`.
