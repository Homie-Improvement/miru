---
module: timekeeping
date: 2026-11-17
problem_type: design_pattern
component: service_layer
severity: medium
audience: both
related_components:
  - api_layer
  - testing_framework
tags:
  - idempotency
  - replay-only
  - bulk-delete
  - timekeeping-gateway
applies_when:
  - A gateway replays a stored answer for a bulk write whose forwarded key is derived from a set of ids
  - A retried bulk call finds fewer live records than it names, because a committed attempt hid them
---

# Replay a bulk write only over the exact id set its key was derived from

## Context

When Timekeeping owns time entries, `Timekeeping::Gateway#bulk_delete` first looks the entries up. The lookup hides discarded entries. A retry after a fully committed bulk delete therefore finds none of them.

The retry cannot run a new delete. It has to ask Timekeeping for the first attempt's stored answer, called a receipt. Timekeeping stores a receipt under the forwarded `Idempotency-Key` and checks that the body matches.

The forwarded key is not the client's key. `EntryWriteClient` derives it from the operation, the set of ids it actually sent, and the client's `Idempotency-Key`. A single DELETE never runs into this, because it sends only one id. A bulk call does.

## Solution

Build the replay from the requested ids, with the same key function and body the first attempt would have used for those ids. In `app/services/timekeeping/entry_write_client.rb`, `replay_bulk_delete` sends `bulk_key(context, "bulk_delete", ids)` with the body `{ "entry_ids" => ids }`. The ids are `bulk_body_ids(entry_ids)`, so the order the client used does not matter.

The consequences follow from the key, not from extra code:

- If the first attempt sent every requested id, the replay sends the same key and body bytes, so it finds the receipt.
- If the first attempt named an id its lookup did not find, for example `[entry, 0]`, it sent fewer ids and was keyed over fewer ids. The replay over the requested ids finds no receipt. Timekeeping answers `404 not_found` and changes nothing, and the client keeps its `422`.
- Only the client's own `Idempotency-Key` can seed a replay. The request-id fallback is new on every resend, so it can never name the first attempt's receipt. `replay_timekeeping_bulk_delete` returns false when `context.idempotency_key` is nil and sends no call.

A receipt, when one is found, must still be checked. `Gateway.all_reported?` is a pure function. It returns true only when the stored `results` list every requested id with `deleted`. An id that is missing, or reported as `not_found`, makes the retry unwritten.

A replay miss counts as "not written", not as a refused write. A missing receipt raises `RecordNotFound`. An older Timekeeping can also refuse the replay's fixed generation, which raises `StaleGeneration` or `Conflict`. The gateway rescues all three inside `replay_timekeeping_bulk_delete`, before `perform` would emit a refusal event for them.

## Why it matters

There are two easy shortcuts, and each gives a false 200. One is to replay under whatever key the client sent. The other is to treat any 2xx stored answer as success. With either one, a delete that never touched some requested entries reports that all of them were deleted.

Keying the replay over the requested id set keeps the rule simple. A replay succeeds only for the exact request that committed in full. No extra state is needed to tell partial attempts apart.

The same reasoning applies to any future bulk replay, such as bulk move, where the forwarded key is derived from the ids sent.

## Evidence

- PR #345, `app/services/timekeeping/entry_write_client.rb`: `replay_bulk_delete` sends `bulk_key(context, "bulk_delete", ids)` and the body `{ "entry_ids" => ids }`. Its comment says only a first attempt that named these ids has a receipt to replay.
- PR #345, `app/services/timekeeping/gateway.rb`: `forward_bulk_delete` calls `replay_timekeeping_bulk_delete(entry_ids)` when the lookup finds no entries. That method returns false when there is no client key or no requested id. It checks the answer with `self.class.all_reported?(answer, entry_ids: requested, result: DELETED_RESULT)` and rescues `ActiveRecord::RecordNotFound, StaleGeneration, EntryWriteClient::Conflict`.
- PR #345, `spec/services/timekeeping/gateway_spec.rb`: tests cover a retry after a `[entry_id, 0]` first attempt (stays unwritten), a keyless retry (no replay call is sent), a stored answer that lists one id as `not_found` (stays unwritten), and a stale-generation refusal (no refusal event).
- PR #345, `spec/requests/api/v1/timesheet_entries/bulk_actions/gateway_spec.rb`: a same-key resend answers 200 with the first attempt's `Idempotency-Key` and body. A partial first attempt's resend sends one replay probe and keeps the 422.
- PR #345, `docs/architecture/timekeeping-soa.md` section 5.1: states that a first attempt that named an id its lookup did not find was keyed over fewer ids, so its retry finds no receipt.
