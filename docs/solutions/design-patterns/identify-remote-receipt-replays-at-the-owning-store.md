---
module: Timekeeping
date: 2026-11-21
problem_type: design_pattern
component: service_layer
severity: high
audience: both
related_components:
  - Timekeeping::EntryWriter
  - Timekeeping::EntryWriteClient
  - Timekeeping::Gateway
tags:
  - idempotency
  - event-emission
  - distributed-writes
applies_when:
  - A caller must suppress events for remote writes answered from stored receipts.
  - A proposed local event mark is used to infer whether a remote write is fresh.
---

# Identify remote receipt replays at the owning store

## Context

Use the receipt holder's replay decision before emitting an event for a forwarded create. An idempotency receipt stores an answer so a retry can return it without performing the write again.

A local mark answers whether this application recorded an event. It does not answer whether another service performed a new write. Those facts differ when the remote service commits but its response never reaches the caller.

## Solution

Keep replay detection beside the stored receipt. Carry that decision separately from the returned entry, because a replay preserves the original status and body.

For Timekeeping, `EntryWriter#answer_from` sets `replayed: true`. The response carries `Idempotency-Replayed: true`, and `EntryWriteClient::CreateAnswer` preserves that fact for the gateway.

Do not replace this decision with a unique local mark. Consider this sequence:

1. Timekeeping commits the entry and its receipt.
2. The HTTP response is lost before the monolith records an event or mark.
3. A retry receives the stored answer.

The missing local mark would permit an event on step 3. The receipt holder correctly identifies that answer as a replay.

Suppressing all replay events has a cost: this sequence produces no create event. That is the required outcome for this observability event, not a promise of eventual event delivery. A feature that requires durable delivery needs a separate design; a local deduplication mark does not supply it.

## Why it matters

An atomic local update can decide whether a local transition occurred. It cannot establish whether a remote transition occurred during the current request. Applying the local pattern across this boundary changes the meaning from “fresh write” to “first success observed here.”

Test a lost response followed by replay. Two successful responses alone do not expose that distinction.

## Evidence

PR #542 adds the replay decision in `timekeeping/app/services/timekeeping/entry_writer.rb` and transports it through `app/services/timekeeping/entry_write_client.rb`. In `app/services/timekeeping/gateway.rb`, `created_entry` suppresses notification when `replayed` is true.

The example `raises no TimesheetEntries::Created across a lost forwarded create answer and its replayed retry` in `spec/services/timekeeping/gateway_spec.rb` asserts zero events across both attempts. The changed `docs/architecture/timekeeping-soa.md` identifies these notifications as observability, not a mandatory audit trail or delivery queue.
