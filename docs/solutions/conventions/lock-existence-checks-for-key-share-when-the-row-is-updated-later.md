---
module: invoices
date: 2026-10-26
problem_type: convention
component: database
severity: medium
evidence_grounding: speculative
audience: both
related_components:
  - data_model
tags:
  - postgresql
  - row-lock
  - for-key-share
  - deadlock
  - existence-check
applies_when:
  - A validation locks a referenced row so it cannot be deleted before commit
  - The same transaction later updates a non-key column of that row, for example in an after_save callback
---

# Lock existence checks FOR KEY SHARE when the row is updated later

## Context

When no foreign key protects a reference column, a validation can check that the row exists and lock it. The lock stops another transaction from deleting the row before commit. `timesheet_entry_id` on invoice line items works this way.

PR #83 first took this lock with `FOR SHARE`. Review found a deadlock. Two invoices created at once that name the same entry both take compatible share locks. Then each invoice's later callback updates that entry's `locked` flag. Each update waits for the other transaction's share lock, so PostgreSQL aborts one of them. Here that surfaces as an unhandled 500.

## Solution

Take the existence lock with `FOR KEY SHARE`:

```ruby
entries_in_invoice_company.where(id: timesheet_entry_id).lock("FOR KEY SHARE").exists?
```

`FOR KEY SHARE` still blocks a delete, and an update of a key column. It does not block an update of a plain column such as `locked`, so the two writers no longer wait on each other. The pending linked-id lookup in the same model uses the same mode.

## Why it matters

`FOR SHARE` looks like the obvious lock for "keep this row alive", and single-connection specs never show the problem. The update that conflicts sits in a different model's callback, far from the lock. Before you pick a lock mode, find every later write to that row in the same transaction.

## Evidence

- PR #83, head commit 3ea539140f8796b0479c88fa54bdb643a60e93d4, `app/models/invoice_line_item.rb`: the comment above `timesheet_entry_found_in_invoice_company` states that `FOR KEY SHARE` still blocks a delete but not the later update of the entry's locked flag, and that `FOR SHARE` would deadlock two invoices saving the same entry at once. `pending_linked_entries_in_invoice_company` uses the same `lock("FOR KEY SHARE")`.
- The deadlock comes from review notes on the pull request, which describe a two-connection probe. The probe is not part of the diff, so the lock-conflict behaviour above is grounded in that code comment and in PostgreSQL's documented lock modes, not in a test in this change.
- Verification step to run: open two PostgreSQL sessions, run `SELECT ... FOR SHARE` on one row in both, then `UPDATE` a non-key column in both and watch one abort. Repeat with `FOR KEY SHARE` and confirm both updates finish.
