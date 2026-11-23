---
module: timekeeping
date: 2026-11-23
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - contract_specs
  - idempotency_receipts
tags:
  - idempotency
  - receipts
  - shared-contract
  - mutation-testing
applies_when:
  - A shared contract example must prove a refused command stored no idempotency receipt
  - Some providers key receipts by target (operation name plus target id), not only by operation_id
---

# Count stored receipts per company to prove a refusal stored none across providers

## Context

A refused command must store no idempotency receipt. A receipt is the stored answer that a retry with the same operation_id gets back. If a refusal stores one, later retries replay the refusal instead of running the command again.

The usual way to check this is to send more requests. You retry with the same key, or reuse the key on another target, and expect a fresh answer. That works only when the receipt lookup can see the receipt. Some providers key mark-billed receipts by target (the operation name `mark_billed <invoice_id>`). A receipt stored for invoice 601 is then invisible to a request for any other invoice. A faulty provider could store a 404 receipt for the foreign invoice, replay that same 404 on retry, and then bill the company's own invoice under the same key. Every reply-based assertion would pass.

## Solution

Give every provider's test setup the same method that returns how many receipts the company holds. Read it before and after the refused request and after the retry:

```ruby
receipts_before = timekeeping_arrange.stored_receipts(company:)
expect(refusal(mark_billed.call)).to eq(refused)
expect(timekeeping_arrange.stored_receipts(company:)).to eq(receipts_before)
expect(refusal(mark_billed.call)).to eq(refused)
expect(timekeeping_arrange.stored_receipts(company:)).to eq(receipts_before)
```

PR #590 adds `stored_receipts(company:)` to all three setups. The in-memory fake counts its receipt store by `company_scope`. The local owner counts `Timekeeping::LocalOwner::Receipt` rows. The Timekeeping service counts `ServiceIdempotencyReceipt` rows.

Then prove the example can fail. Add a broken fake that still answers 404 but stores a receipt (the `refused_invoice_receipt: true` policy). The shared group must fail against it.

## Why it matters

A count does not depend on how a provider builds its receipt key, so one shared example covers every provider. A probe through replies depends on key shape, and it passes silently on the provider where the bug is most likely. Without the broken fake you cannot tell whether the count check can fail at all.

## Evidence

- `spec/contracts/timekeeping/reservations_examples.rb` in PR #590: the shared "another company's invoice" mark-billed example checks `stored_receipts(company:)` after the refusal and after the retry. Its comment says receipts are keyed by target on some providers, so only a count shows one stored for the refused invoice.
- `stored_receipts` is added in `spec/support/timekeeping/fake_arrange.rb`, `spec/support/timekeeping/local_owner_arrange.rb` and `timekeeping/spec/support/timekeeping_arrange.rb`. The fake's count comes from `count(company_scope:)` in `spec/support/timekeeping/idempotency_receipts.rb`.
- `spec/contracts/timekeeping/mutation_spec.rb` adds the mutant "stores a receipt for a refused foreign invoice", backed by the `refused_invoice_receipt` policy in `spec/support/timekeeping/fake_timekeeping.rb`.
- After the per-provider copies were removed, the author ran the shared examples. The monolith contract run gave 234 examples, 0 failures. `timekeeping/spec/contracts/reservation_provider_spec.rb` gave 27 examples, 0 failures.
