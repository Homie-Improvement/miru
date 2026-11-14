---
module: timekeeping/handoff
date: 2026-10-27
problem_type: design_pattern
component: timekeeping_handoff
severity: high
evidence_grounding: anchored
grounding_evidence: lib/timekeeping/handoff/legacy_operations_check.rb listed_receipts now keeps only current committed intents whose [company_id, invoice_id, operation_id] key is committed in source_intents; spec/lib/timekeeping/handoff/legacy_operations_check_spec.rb covers the one-sided and two-company cases.
audience: both
related_components:
  - reconciliation
tags:
  - reconciliation
  - listed-corrections
  - expected-differences
  - multi-tenant-keys
applies_when:
  - A reconcile step compares a frozen source with a current read and accepts a list of expected differences
  - An expected difference explains a field change, such as a state column, on a row
---

# List a state correction only for rows that match on both sides, keyed by the full unique key

## Context

The handoff reconcile step compares the `invoice_operation_intents` rows frozen at the checkpoint with a fresh read. A list of corrections tells it which differences are expected. A correction for a legacy committed intent matches on check, row key and the field `"state"`. So once it is listed, any state difference on that row counts as explained.

Before PR #244 both sides came from one read, so the list could be built from the current rows without harm. Once the two sides really differ, how the list is built decides which edits reconcile can see.

## Solution

Build the correction only for a row that holds the expected value in the source and in the current read. Match the two sides on the row's full unique key, company included.

```ruby
company_receipt_key = ->(intent) { [intent["company_id"], *Reconciliation::RECEIPT_LINK_KEY.call(intent)] }
committed_at_checkpoint = source_intents
  .select { |intent| intent["state"] == "committed" }
  .to_set(&company_receipt_key)
intents
  .select { |intent| intent["state"] == "committed" }
  .select { |intent| committed_at_checkpoint.include?(company_receipt_key.call(intent)) }
```

`LegacyOperationsCheck.listed_receipts` now takes `source_intents:` and `intents:` for this reason.

## Why it matters

Each one-sided choice hides one direction of edit:

- Built from the current read only, the list explains a failed-to-committed edit made after the checkpoint.
- Built from the source only, it explains a committed-to-failed or committed-to-pending edit.
- The intersection explains neither, and still lists the expected difference for intents that stayed committed.

The key must carry the company because intents are unique per company, invoice and operation. Keyed on invoice and operation alone, company 12's committed intent vouches for company 11's intent with the same ids. Company 11 can then flip from failed to committed after the checkpoint and pass reconcile.

The general rule: a correction that explains a change must not be derivable from the changed side alone. This extends the existing rule to derive expected differences from the planned copy, not the target.

## Evidence

- PR #244 changes `lib/timekeeping/handoff/legacy_operations_check.rb` so `listed_receipts(source_intents:, intents:, legacy_retired_at:)` lists a receipt only for an intent committed in both lists, keyed by `company_id` plus `Reconciliation::RECEIPT_LINK_KEY`.
- `spec/lib/timekeeping/handoff/legacy_operations_check_spec.rb` checks that intents changed from committed to failed, failed to committed, or deleted get no listed receipt. A second example checks that company 12's committed intent does not list a receipt for company 11's intent with the same invoice and operation ids.
- The author ran that spec with the lookup keyed on invoice and operation only and it failed, because company 11 was listed. With the company in the key, it passed with 2 examples, 0 failures.
- `spec/lib/timekeeping/handoff/runner_legacy_handoff_spec.rb` adds a runner example where a legacy intent committed at the checkpoint is failed on resume and reconcile refuses with "Reconciliation found unexplained differences".
