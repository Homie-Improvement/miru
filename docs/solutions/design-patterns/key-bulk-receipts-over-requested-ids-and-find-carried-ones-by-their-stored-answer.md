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
tags:
  - idempotency
  - bulk-write
  - bulk-move
  - bulk-delete
  - rollback
applies_when:
  - Choosing the id set a bulk write's idempotency key is derived from
  - Replaying a bulk receipt the other owner stored before an ownership change
---

# Key bulk receipts over the requested ids, and find carried ones by their stored answer

## Context

`EntryWriteClient.bulk_idempotency_key` builds a bulk write's key from the client key, the operation and a list of entry ids. Which list is the question. A bulk move or delete writes only the entries it finds and may move. The replay check in `bulk_write` runs before that lookup, so it can only build a key from the ids the client requested.

If the receipt is stored under the ids written, a retry whose found or movable set changed misses it. Two failures follow:

- A bulk delete that named a missing id answers `:not_found` instead of its committed success.
- A partly skipped bulk move writes again. It overwrites a later edit and adds audit and outbox rows.

## Solution

- **Key the receipts this store writes over the requested ids.** In PR #545, `local_bulk_key(operation, identity)` keys over `identity.fetch("entry_ids")`. That is the same key the replay builds before the lookup runs.
- **Find a receipt the other owner carried in by its own answer.** A forwarded bulk write is keyed over the ids it sent, and a rollback copies that receipt in unchanged. The sent ids cannot be rebuilt from the entries as they are now. So `replay_carried_bulk` lists this actor's bulk receipts through `LocalOwner.stored_bulk_receipts`. It picks the one whose key equals `bulk_request_key(operation, receipt.entry_ids)`, where `entry_ids` comes from the stored `results` body. Then it replays that receipt. The receipt carries Timekeeping's fingerprint, so the retry is refused as a reused key and nothing is written.
- **Return a replayed answer like a first answer.** The `BulkResult` carries the entries the scoped lookup finds now. A screen that replaces its rows with the response then shows the moved entries.

The cost: the two owners' bulk keys match only when every requested id was found and movable. Each owner must also check the other owner's key form.

## Why it matters

A rule that keys over current state only holds while that state stays the same between attempts. Retries often happen after other edits. A test with a fixed set of entries passes under either keying rule, so the bug stays hidden until the eligible set grows, shrinks or empties.

## Evidence

- PR #545, `app/services/timekeeping/gateway.rb`:
  - `local_bulk_move` and `local_bulk_delete` now pass `local_bulk_key(...)`, not `bulk_request_key(..., ids)`.
  - `replay_carried_bulk` matches the carried receipt by `receipt.entry_ids`.
  - `bulk_write` runs it before `bulk_entries` while the prepared store owns the entries.
- PR #545, `app/services/timekeeping/local_owner.rb` adds `StoredBulkReceipt` and `self.stored_bulk_receipts`. They read the entry ids from each receipt's `results` body.
- PR #545, `spec/services/timekeeping/gateway_spec.rb` adds these examples:
  - "answers a prepared bulk delete retry that named a missing id from the receipt of its first attempt"
  - "answers a partly skipped prepared bulk move retry from its first receipt after the movable entries change"
  - "refuses a carried partial bulk move retry after a skipped entry becomes movable and leaves the later edits"
  - "refuses a carried bulk delete retry whose sent entries are gone, even though nothing is found to delete"
- The PR's review record shows the first two examples fail when the receipt key goes back to the ids written. The last two fail when `replay_carried_bulk` is removed.
