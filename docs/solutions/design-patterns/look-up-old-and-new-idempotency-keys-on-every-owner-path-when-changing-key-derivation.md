---
module: timekeeping
date: 2026-11-21
problem_type: design_pattern
component: service_layer
severity: high
audience: both
related_components:
  - Timekeeping::Gateway
  - Timekeeping::LocalOwner
  - Timekeeping::EntryWriteClient
tags:
  - idempotency
  - ownership-handoff
  - re-cutover
  - rollback
  - receipts
applies_when:
  - Changing how Timekeeping::Gateway or EntryWriteClient derives an idempotency key
  - Adding a write path that runs after entry ownership moves between the monolith and Timekeeping
---

# Look up old and new idempotency keys on every owner's path when key derivation changes

## Context

An idempotency receipt is the stored answer to a write, saved under the client's key. A retry with the same key gets that answer back and does not write again.

Time entries can be owned by the monolith's prepared store or by the Timekeeping service. Ownership moves in both directions: a rollback hands entries back to the monolith, and a re-cutover gives them to Timekeeping again. Before PR #545, the prepared store saved receipts under the raw client key. Forwarded writes used `EntryWriteClient.idempotency_key`, a UUID built from the client key, the operation and the entry id. So a retry after either move found no receipt and wrote a second entry.

PR #545 makes prepared writes use the same derived key. But receipts already saved under the raw key stay in the monolith's `idempotency_records`. Exporting the checkpoint does not delete them. The gateway's comments assume Timekeeping looks a retry up only under the key it is sent, and so would write those retries again; this change does not show Timekeeping's own behaviour.

## Solution

Treat a key change as a change to every lookup, not only to the write.

- **Ordered keys, first answer wins.** `replay_keys(derived_key)` returns `[derived_key, context.idempotency_key]`. `replay_local` tries each key in order and returns the first stored answer. A key-reused refusal counts as an answer, so a refusal under the derived key never falls through to the raw key or to a write. With no client key, nothing is looked up, because a key built from the request id is new on every retry.
- **The other owner's path reads old receipts too.** While Timekeeping owns the entries, update, destroy and both bulk writes call `replay_committed`, which sends `:timekeeping` ownership to `replay_prepared_receipt`. Create does not go through `replay_committed`: `forward_create` calls `replay_prepared_receipt` directly, before `write_client.create_entry`. `LocalOwner.replay` refuses every request while Timekeeping owns the entries, because of the generation fence (a check that this store owns the entries at the current ownership generation). So the PR adds `LocalOwner.stored_answer_for`. It reads a receipt without that fence and never locks or writes.
- **Each operation keeps its own replay handling.** A create answer goes through `hydrate`, an update through `replayed_update`, a destroy through `EntryLookup.replayed` and `authorize`. A bulk answer becomes a `BulkResult`. A bulk receipt's body is `{ "results" => [...] }`, not an entry, so single-entry hydration would drop it.
- **A proven commit with no stored answer refuses.** In `local_carried_create`, a matching legacy receipt proves the create committed. If the copied row is missing from the prepared store, the gateway raises `EntryWriteClient::Error` and writes nothing.

## Why it matters

Duplicate time entries land on users, and reconciliation does not catch them, because the receipt rows themselves match. Fixing the key on the write path alone covers only new writes. Old receipts are protected only when each owner's path reads them before it writes. If a refusal can fall through to the next key, a retry with other values gets written instead of refused.

## Evidence

- PR #545, `app/services/timekeeping/gateway.rb`:
  - `replay_local` loops over `keys` and returns on the first non-nil outcome.
  - `replay_keys` lists the derived key, then the raw client key.
  - `update`, `destroy` and `bulk_write` call `replay_committed`, which sends `:timekeeping` ownership to `replay_prepared_receipt`.
  - `forward_create` calls `replay_prepared_receipt` directly, before `write_client.create_entry`.
  - `local_carried_create` raises `EntryWriteClient::Error` when the carried row is nil.
- PR #545, `app/services/timekeeping/local_owner.rb` adds `self.stored_answer_for`, which calls `stored_answer_without_fence` with no lock and no write.
- PR #545, `spec/services/timekeeping/gateway_spec.rb` covers these cases with a write client that allows no calls, so any forward fails the example. The re-cutover bulk delete and bulk move examples stub `read_client.show_entry`, so the Timekeeping lookup can run while nothing is forwarded:
  - A receipt re-keyed to the raw client key answers create, update, destroy, bulk delete and bulk move after the owner flips to `timekeeping`.
  - A derived-key receipt with another fingerprint is refused without falling through to a matching raw-key receipt.
