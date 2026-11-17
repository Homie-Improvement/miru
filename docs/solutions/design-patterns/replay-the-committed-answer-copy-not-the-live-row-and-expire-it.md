---
module: timekeeping
date: 2026-11-17
problem_type: design_pattern
component: timekeeping_gateway
severity: high
audience: both
related_components:
  - legacy_create_receipts
  - idempotency
tags:
  - idempotency-key
  - replay
  - receipt
  - access-control
  - retention
applies_when:
  - A create or write replays an earlier answer when a client repeats its Idempotency-Key
  - A new receipt table is added for a store that had no request receipts
---

# Replay the committed answer copy, not the live row, and expire that copy

## Context

A receipt lets a retried request get the first attempt's answer back instead of writing again. The cheap design stores only the new row's id and reloads that row on replay. That returns the row as it is now, not the answer the first attempt gave.

The gap is a data leak, not only a stale value. Take an admin who creates an entry for an employee with key K. The admin is then made an employee. Someone else adds a confidential note to the entry. The former admin repeats K with the same body. The fingerprint matches, so a live-row replay returns the new note to a person who never saw it and may no longer read it. The replay only checks that the key and body match. It does not re-run the access check that a normal read would run.

## Solution

- Store the answer, not a pointer. Right after `save!`, write the row's stored values into the receipt in the same transaction. In `Timekeeping::Gateway#legacy_create` this is `entry_attributes: entry.attributes_for_database`, kept in a `jsonb` column.
- Rebuild the replay from that copy: `TimesheetEntry.instantiate(receipt.entry_attributes).tap(&:readonly!)`. Nothing reads the current row, so a later edit or delete never reaches the retry, and a deleted entry is not brought back.
- Do not give the receipt a foreign key to the row (`timesheet_entry_id` is a plain `bigint`). The receipt must keep answering after the row is deleted or moves to another store.
- Because the receipt now holds a copy of user data, give it an `expires_at` with an index. Set it to now plus the retry window (`LegacyCreateReceipt::RETENTION`, shared with the other receipt table). Delete expired receipts under the receipt-key lock (`LocalOwner::WriteSteps.lock_key`), before the lookup, so an expired receipt never answers. The receipt keeps its copy of the entry, including a note later removed from the entry, until it expires. After that the copy stays until a later keyed legacy create runs the prune, because the prune only runs inside `legacy_create`.
- Fingerprint the request values, not the saved row. The row also holds defaults read from current state, which can change between attempts.

The trade-off: a stored copy costs storage and a retention rule. A live reload costs nothing extra but replays later edits without an access check. Take the copy. The other way to fix the leak is to re-check current access before replaying the live row, but that still answers something the first attempt never answered.

## Why it matters

Without the copy, any receipt-based replay becomes a way to read later changes to a row by repeating an old key. Without retention, the copy fixes the leak but keeps every note forever, even after the entry is edited or deleted. Both halves are needed.

## Evidence

- PR #347 adds `app/services/timekeeping/gateway.rb` `legacy_create`. It writes `entry_attributes: entry.attributes_for_database` with the receipt and replays with `TimesheetEntry.instantiate(receipt.entry_attributes).tap(&:readonly!)`. It calls `LegacyCreateReceipt.expired.delete_all` after `LocalOwner::WriteSteps.lock_key` and before `find_by`.
- `db/migrate/20261030120000_create_legacy_create_receipts.rb` adds a `jsonb :entry_attributes` column. It adds `timesheet_entry_id` with no foreign key, plus an indexed `expires_at`. Its comments give the reasons for both.
- `app/services/timekeeping/legacy_create_replay.rb` says the fingerprint covers request values, never the saved row.
- `spec/services/timekeeping/gateway_spec.rb` contains the example "legacy create retried with the same key after the creator lost access and the entry was edited returns the committed answer, not the later note". It removes the creator's admin role, edits the note through the gateway, then asserts the replay shows "original note" and adds no entry.
- The same spec covers the deleted case ("a legacy create retried after its entry was deleted replays the first answer and does not recreate the entry"). It also covers expiry ("a legacy create repeated after its receipt expired prunes that receipt and records a new entry"), which asserts `expires_at` is 24 hours after `created_at`.
