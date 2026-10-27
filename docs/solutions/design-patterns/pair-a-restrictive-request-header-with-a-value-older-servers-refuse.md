---
module: timekeeping
date: 2026-10-27
problem_type: design_pattern
component: timekeeping_gateway
severity: high
evidence_grounding: anchored
grounding_evidence: 'app/services/timekeeping/entry_write_client.rb adds REPLAY_ONLY_IF_MATCH = "replay-only" sent beside Idempotency-Replay: only; timekeeping/spec/requests/v1/entry_writes_spec.rb asserts a headerless DELETE with If-Match replay-only answers 409 version_conflict and discards nothing; gateway.rb maps that Conflict to RecordNotFound.'
audience: both
related_components:
  - timekeeping_service
  - contracts
tags:
  - rollout
  - backward-compatibility
  - idempotency
  - if-match
  - mixed-version
applies_when:
  - Adding a request header that makes a write route do less than it normally does
  - The client and the service deploy separately or can be rolled back separately
---

# Pair a restrictive request header with a value older servers refuse

## Context

The monolith now sends `Idempotency-Replay: only` on a retried DELETE to Timekeeping. The header means: answer only from a stored receipt, and never delete. A Timekeeping instance released before the header existed does not read it. To that instance the request is an ordinary DELETE. An admin's retry could then delete a colleague's entry that the monolith's own scope check had rejected. Shipping the service before the client does not prevent this: a service rollback, or a rollout where old and new instances run side by side, still routes the request to code that ignores the header.

## Solution

Send a second signal that every older server already refuses, on the same request. Here the client sends `If-Match: replay-only`. That value is never a version number, so an older service answers `409 version_conflict` before any write. A newer service reads the receipt first, so a real stored answer still replays.

- `EntryWriteClient::REPLAY_ONLY_IF_MATCH = "replay-only"` is sent with the header on every replay call.
- On the replay path the gateway turns `EntryWriteClient::Conflict` into the same `RecordNotFound` as every other miss. Callers see one uniform answer, whichever server version replied.
- The contract (`contracts/timekeeping/entry_api.yml` `rules.replay_only`) records why the value exists, so no one later "tidies" it away.

To use the pattern elsewhere, find a check the old server already runs before it writes and that a fixed value always fails. Confirm that check happens before any side effect on the old code path. Then test the old behaviour directly: send the companion value without the new header and assert a refusal with nothing changed.

## Why it matters

A new header that restricts behaviour fails open on any server that ignores it. The failure appears only during rollout or rollback, which tests on a single version never exercise. The companion value makes it fail closed. It also removes the need for a feature flag or a fixed deploy order.

The cost: the companion value takes over a field (`If-Match`) for a second purpose. The client must also map the old server's refusal (409) back to the answer the new server gives (404). Otherwise a rollout leaks a new status to callers.

## Evidence

- PR #210, `app/services/timekeeping/entry_write_client.rb`: adds `REPLAY_ONLY_IF_MATCH` with a comment that an older Timekeeping refuses it as `version_conflict` and does not discard the entry. `replay_destroy_entry` sends it with `replay_only: true`.
- PR #210, `app/services/timekeeping/gateway.rb`: `replay_timekeeping_destroy` rescues `EntryWriteClient::Conflict` and raises `EntryLookup.not_found`.
- PR #210, `timekeeping/spec/requests/v1/entry_writes_spec.rb`: "refuses a DELETE whose If-Match is replay-only with version_conflict and discards nothing" sends the value without the header and asserts 409, `discarded_at` nil and unchanged write counts.
- PR #210, `spec/services/timekeeping/gateway_spec.rb`: "answers not found when a provider that ignores the replay header refuses the replay as a version conflict".
- PR #210, `contracts/timekeeping/entry_api.yml` and `docs/architecture/timekeeping-soa.md` section 5.1 state the rule.
