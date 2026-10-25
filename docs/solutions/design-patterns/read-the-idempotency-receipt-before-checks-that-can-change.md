---
module: timekeeping
date: 2026-10-25
problem_type: design_pattern
component: entry_writer
severity: medium
evidence_grounding: anchored
grounding_evidence: timekeeping/app/services/timekeeping/entry_writer.rb in 6a1a783 reads the receipt under its advisory lock before the generation compare and project_known?; entry_writes_spec.rb replays a committed create after its project leaves the reference facts
audience: both
related_components:
  - entry_command
  - reference_client
  - idempotency_receipts
tags:
  - idempotency
  - retries
  - receipts
  - ordering
applies_when:
  - A write route stores receipts so a retry after a lost response replays the first answer
  - The route also refuses on state that can change between the first attempt and the retry
---

# Read the idempotency receipt before any check whose answer can change

## Context

Entry writes store a receipt for each 2xx answer. A retry with the same key and body is meant to get the same answer back. The writer also refuses a write when the `Ownership-Generation` header is stale, or when the body names a project the reference facts no longer hold.

In an earlier version of the change, the missing-project refusal ran in `EntryCommand.build`, before the receipt was read. Consider this order: a create commits, its response is lost, then the project is removed before the retry. The retry gets 404 even though the entry exists. A generation advance between the attempt and the retry would cause the same failure if the generation compare ran first.

## Solution

Order the steps by whether their answer can change between attempts:

1. Before the receipt, run only checks that depend on the request itself: authentication, the key, body parsing, the credential scan and id formats.
2. Take the receipt-key lock and re-read the receipt. Replay the stored answer on the same fingerprint, or answer 422 `idempotency_key_reused` on a different one.
3. Only after that, run checks that depend on state that can move: the generation compare, project existence, row locks and the entry rules.

`EntryWriter#write` follows this order. `project_known?` is a pure check on the facts that the command already fetched, so moving it after the receipt needs no new query.

## Why it matters

A refusal that runs before the receipt turns a committed write into a false failure on retry. The client then believes nothing was written, and it may create the entry again under a new key. The bug is rare and easy to miss in review, because every check is correct on its own. Only the order between the check and the receipt is wrong.

One exception remains and is disclosed. The reference facts are fetched before the transaction, because the read must not hold locks during a network call. So while the monolith is down, a retry of a committed write gets 503, not its stored success. This is acceptable because the 503 is retryable and never creates a second entry. A 404 or 409 tells the client the write failed, which is wrong after a commit.

## Evidence

- PR #40, head commit 6a1a783a33e2d6eca8ffcec874eb6f1fcef2658b: `timekeeping/app/services/timekeeping/entry_writer.rb`. In `write`, `lock_receipt_key` and `find_receipt` run before `locked_generation`, `generation_matches?` and `project_known?`. The class comment explains that both come after the receipt so a retry still replays.
- `timekeeping/app/services/timekeeping/entry_command.rb` keeps only request-shape checks and the reference fetch. `timekeeping/spec/services/timekeeping/entry_command_spec.rb` expects a built command when the facts lack the project.
- `timekeeping/spec/requests/v1/entry_writes_spec.rb` replays a committed create on retry after its project is no longer in the reference facts. It expects the original 201 body, while a new key gets 404.
- The PR body's notes on the written rules disclose the 503-before-replay case.
