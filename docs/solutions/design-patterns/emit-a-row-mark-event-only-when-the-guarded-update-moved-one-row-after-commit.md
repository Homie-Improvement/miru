---
module: invoices
date: 2026-11-15
problem_type: design_pattern
component: service_layer
severity: medium
audience: both
related_components:
  - observability
  - background_job
tags:
  - outbox
  - events
  - after-commit
  - idempotency
  - undeliverable
applies_when:
  - A delivery path marks a row with a terminal flag and tells an operator about it
  - The same row can be reached again by inline delivery or a recovery sweep
---

# Emit a row-mark event only when the guarded update moved one row, and only after commit

## Context

This change assumes, as the issue states and the change does not confirm, that the Timekeeping service refuses a row saved under an older ownership generation on every retry; the fake answers 409 stale_generation in the specs. `Invoices::OutboxDelivery` therefore sets `undeliverable_at` on that row instead of counting an attempt. It also emits `invoices.undeliverable_operation` so an operator can act.

The same row can be reached more than once, by inline delivery or by the recovery sweep. The mark is also written inside the delivery transaction, and that transaction can still roll back. If the event fires right after the update, an operator can get two alerts for one row, or an alert for a mark that never committed.

## Solution

- Write the mark with a guarded update that only matches an unmarked, undelivered row. Use the returned row count to decide whether to notify.
- Send the event from `ActiveRecord.after_all_transactions_commit`, so it runs only once the mark is committed.
- Skip marked rows at both entry points: the locked re-read in `deliver`, and the query in `deliver_undelivered`.

```ruby
when :undeliverable
  marked = undelivered.where(undeliverable_at: nil).update_all(undeliverable_at: Time.current)
  notify_undeliverable(item) if marked == 1
```

Keep the payload to what names the row (`company_id`, `operation_id`, `kind`). Never include the request body or a token.

## Why it matters

The update count is the only fact that says this call made the change. Every earlier read can be stale. Waiting for the commit ties the alert to stored state, not to an attempt that might be undone. A test with committed data proves both: deliver twice, then expect one event and an unchanged row.

A marked commit row still blocks billing for its invoice. The billing check reads `delivered_at: nil` commit rows and does not look at `undeliverable_at`. The event is how an operator learns the row needs a person.

## Evidence

- PR #322, `app/services/invoices/outbox_delivery.rb`: in `record`, the `:undeliverable` branch calls `notify_undeliverable(item) if marked == 1`. `notify_undeliverable` wraps `UndeliverableOperation.notify` in `ActiveRecord.after_all_transactions_commit`.
- `app/events/invoices/undeliverable_operation.rb` and `app/jobs/recover_invoice_operation_intents_job.rb` in PR #322: the event module sends exactly three keys, and `deliver_undelivered` filters on `undeliverable_at: nil`.
- `spec/services/invoices/outbox_delivery_spec.rb` in PR #322: the committed-data example delivers a stale_generation commit row twice and expects one `invoices.undeliverable_operation` event, an unchanged row and no second request. The abort-row example expects `attempts` at 0 and exactly one event with kind `abort`.
- `spec/services/invoices/reservation_boundary_spec.rb` in PR #322 expects `mark_billed` to raise `PrepareRetryable` with `COMMIT_UNDELIVERED_REASON` while the commit row is marked undeliverable.
