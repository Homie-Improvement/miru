---
module: timekeeping
date: 2026-10-27
problem_type: design_pattern
component: timekeeping_gateway
severity: high
evidence_grounding: anchored
grounding_evidence: gateway.rb destroy rescues RecordNotFound from find_authorized only on :timekeeping and calls replay_timekeeping_destroy, which runs EntryLookup.replayed and authorize before returning true; entry_writer.rb returns refusal(:not_found) right after a receipt miss when command.replay_only.
audience: both
related_components:
  - timekeeping_service
  - entry_lookup
  - fake_timekeeping
tags:
  - idempotency
  - soft-delete
  - retry
  - authorization
  - receipts
applies_when:
  - A write path looks the record up and authorizes it before sending the write
  - The write is a delete or discard that hides the record from that lookup
  - Retries rely on a server-side idempotency receipt
---

# Replay a lost delete answer through a receipt-only request

## Context

`Gateway#destroy` looks the entry up through Timekeeping's show route, runs the policy, then sends DELETE with an `Idempotency-Key`. The show route hides discarded entries. So when the first delete committed but its answer was lost, the retry got 404 at the lookup. It never sent the second DELETE, and Timekeeping's stored receipt was never reached. Receipt-first ordering on the server did not help, because the request never arrived.

Two obvious fixes are wrong. Treating the 404 as success reports deletes that never happened, for unknown ids and other tenants' ids too. Sending a plain DELETE after the 404 skips the gateway's actor scope and policy. Timekeeping's own destroy would let an admin delete a colleague's entry the gateway had rejected.

## Solution

After a lookup not-found, send a request the server can answer only from a stored receipt:

1. The gateway rescues only `ActiveRecord::RecordNotFound`, and only when the owner is `:timekeeping`. A 503 or any other lookup error still propagates. The legacy branch keeps no receipts and still answers 404.
2. `replay_destroy_entry` reuses the destroy key derivation and the same empty body, so the stored fingerprint matches. It adds `Idempotency-Replay: only`.
3. The service marks the command `replay_only` only for the `:destroy` route and the exact value `only`. In `EntryWriter#write` it returns `not_found` right after a receipt miss, before the generation check, row locks or any write. The receipt scope (company, actor from the signed token, operation, key) authenticates the replay. A client-chosen request id alone cannot reach someone else's answer.
4. The replayed row goes through `EntryLookup.replayed`. That method shares `check_target` with `find`, so the same id, company and scope checks apply. Then the gateway runs `authorize` before returning true.

Keep the test fake in the same order as the service: receipt, then replay-only miss, then generation. Otherwise a moved generation makes the fake refuse a replay the service would answer.

## Why it matters

Any lookup-then-write flow where the write hides the record breaks idempotent retries in the same way. A replay request that can never write keeps three things together: retries succeed, nothing is deleted twice, and every miss looks the same (unknown, foreign, out of scope, no receipt).

One trade-off is deliberate. Re-running the policy means a user whose role was revoked after the first delete committed gets 403 on the retry, even though the delete happened. Skipping the re-check would let that user read the stored entry body for as long as the receipt exists. Receipt retention (`retention_hours: 24`) is a minimum, not an expiry. A replay works until the receipt row is removed.

## Evidence

- PR #210, `app/services/timekeeping/gateway.rb`: `destroy` rescues `RecordNotFound` only when `owner == :timekeeping`. `replay_timekeeping_destroy` calls `EntryLookup.replayed` and then `authorize`.
- PR #210, `app/services/timekeeping/entry_lookup.rb`: `replayed` and `find` both call `check_target`.
- PR #210, `timekeeping/app/services/timekeeping/entry_command.rb`: `REPLAY_ROUTES = %i[destroy]` and `replay_only?`. `timekeeping/app/services/timekeeping/entry_writer.rb`: `return WriteOutcome.refusal(:not_found) if command.replay_only` after the receipt read.
- PR #210, `spec/support/timekeeping/fake_timekeeping.rb`: the generation check moved inside `@receipts.answer`, after the replay-only check.
- PR #210, `spec/contracts/timekeeping/entry_replay_examples.rb`: shared examples run against both the fake and the service through `timekeeping/spec/contracts/entry_provider_spec.rb`.
- PR #210, `spec/services/timekeeping/gateway_spec.rb`: lost-answer retry returns true with one discard, while colleague, foreign-company, out-of-scope, new-request-id and 503 cases do not.
- PR #210, `contracts/timekeeping/idempotency.yml`: the comment that 24 hours is a minimum retention.
