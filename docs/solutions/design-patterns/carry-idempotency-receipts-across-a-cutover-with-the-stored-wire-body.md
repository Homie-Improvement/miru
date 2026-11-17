---
module: timekeeping
date: 2026-11-17
problem_type: design_pattern
component: timekeeping_handoff
severity: high
audience: both
related_components:
  - timekeeping_gateway
  - legacy_create_receipts
tags:
  - idempotency
  - cutover
  - fingerprint
  - receipts
  - handoff
applies_when:
  - Moving idempotency receipts from one store to another that fingerprints the request body as sent
  - A retry can arrive after ownership flips to a store that never saw the first attempt
---

# Carry idempotency receipts across a cutover with the wire body stored at first write

## Context

In this repository, a time entry create can commit in the legacy store with an Idempotency-Key. The client can lose the answer and retry after the first cutover, when Timekeeping owns entries. This change assumes that Timekeeping matches a receipt by operation, key and a SHA-256 of the body it receives. The change does not include Timekeeping's own code. It encodes the assumption in comments in `lib/timekeeping/legacy_create_receipt_conversion.rb` and models it with the stub in `spec/lib/timekeeping/handoff/runner_legacy_create_replay_spec.rb`. On the monolith side, `forwarded_fingerprint` hashes `JSON.generate(JSON.parse(body))` to mirror what the change assumes Timekeeping computes, so in that function key order counts and whitespace does not. To replay the original entry, the carried receipt must hold the hash of the exact body the retry will send.

Two ways of rebuilding that body later both fail:

- **Defaults read from current state.** `create_body` fills `bill_status` from the project's billing default. If the project becomes non-billable between the attempts, a rebuilt body hashes differently. Under the assumed receipt matching, Timekeeping would then answer 422 to a request the client did not change. Only the runner spec's stub models that answer.
- **Loose input the old model accepted.** The legacy model casts `work_date: "2026-11-17T00:00:00Z"` to a date. A comment in the gateway, and a check run during review, say that Timekeeping refuses any `work_date` that is not `YYYY-MM-DD` before it reads its receipt. The change does not include Timekeeping's validator, so this is an assumption. Under it, a body that keeps the raw text can never replay.

## Solution

1. **Save the body at first write.** Build it with the same `create_body` the forwarded path uses, for the same resolved user, before the save. Store it in a `text` column (`forwarded_body`), not `jsonb`, because `jsonb` does not keep key order.
2. **Normalize to the receiver's format.** Replace fields the receiver validates strictly with the value the old store saved, keeping the key's position. In this change, `forwarded_body_for` writes `entry.work_date.iso8601`.
3. **Match the retry on request values, then resend the stored bytes.** After the flip, the gateway looks up the unexpired legacy receipt for the request's scope. It compares the legacy request-values fingerprint, which leaves out defaults. On a match it sends `JSON.parse(receipt.forwarded_body)`. On a mismatch it raises the same 422 `idempotency_key_reused` refusal and sends nothing. Do this before any check that can change between attempts, such as resolving the target user.
4. **Refuse the cutover for receipts you cannot carry.** A live receipt written before the column existed has no body. It cannot be carried, and its retry cannot be replayed from Timekeeping. After the flip the gateway would still find that receipt through `LegacyCreateReceipt.unexpired`, and `forward_carried_create` would call `JSON.parse(nil)` and raise. So the cutover waits for such receipts to expire. `LegacyCreateReceiptConversion` returns a refusal that names the receipt and its expiry, and the operator reruns the cutover after it expires. Receipts that expire at or before `captured_at` are left out. This uses the same boundary the legacy store uses to treat a receipt as expired.
5. **Build the carried answer from the committed copy.** Use the receipt's `entry_attributes`, never the live row. An edit made after the create must not change the replayed answer.

## Why it matters

A receipt only works if both sides compute the same fingerprint from the same bytes. Anything recomputed at a later time reads a later state, so the only safe input is what was captured when the write committed. The refusal step matters as much: a receipt that cannot be carried leaves its client's retry with no way to replay from Timekeeping, and those are exactly the clients who retried during the deploy.

## Evidence

- PR #351, `db/migrate/20261117120000_add_forwarded_body_to_legacy_create_receipts.rb`: adds `forwarded_body` as `text`. Its comment explains that `jsonb` loses key order and that the body holds defaults that cannot be rebuilt later.
- PR #351, `app/services/timekeeping/gateway.rb`: `legacy_create` builds the body before `save_legacy_entry`. `forwarded_body_for` rewrites `work_date` to `entry.work_date.iso8601`. `forward_create` and `carried_legacy_create` match on request values and resend the stored body. `carried_legacy_create` reads `LegacyCreateReceipt.unexpired`, and `forward_carried_create` parses `receipt.forwarded_body`.
- PR #351, `app/services/timekeeping/legacy_create_replay.rb`: `forwarded_fingerprint` hashes `JSON.generate(JSON.parse(wire_body))`. `spec/services/timekeeping/legacy_create_replay_spec.rb` shows that whitespace does not change the hash and key order does.
- PR #351, `lib/timekeeping/legacy_create_receipt_conversion.rb`: leaves out expired receipts and refuses live ones that have no forwarded body. `spec/lib/timekeeping/legacy_create_receipt_conversion_spec.rb` covers the expiry boundary and the refusal.
- PR #351, `spec/services/timekeeping/gateway_spec.rb`: examples cover a billing default that changes before the flip, a timestamp `work_date` (checked only against `TimekeepingRules::EntryDecision::DATE`), and a resolver that refuses on the retry. `spec/lib/timekeeping/handoff/runner_legacy_create_replay_spec.rb` shows the retry after the cutover replays with no second entry recorded, against a stub that models the assumed Timekeeping receipt rule.
