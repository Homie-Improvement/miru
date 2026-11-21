---
module: Timekeeping
date: 2026-11-21
problem_type: design_pattern
component: service_layer
severity: medium
audience: both
related_components:
  - Timekeeping::Gateway
  - Timekeeping::LegacyCreateReplay
  - TimesheetEntry
tags:
  - idempotency
  - event-emission
  - ownership-cutover
  - carried-receipt
applies_when:
  - Changing which create exits in Timekeeping::Gateway call created_entry or notify_created
  - A write retried across an ownership flip is answered by a store that never saw the first attempt
---

# Do not raise a create event on a carried legacy receipt, even when Timekeeping answers fresh

## Context

`TimesheetEntries::Created` must be raised once per create, whichever store owns the entries. For a create forwarded to Timekeeping, the gateway asks one question: did Timekeeping serve this answer from its stored receipt? Timekeeping says so with the `Idempotency-Replayed: true` response header. `Timekeeping::Gateway#created_entry` raises the event unless `replayed` is true.

One create exit breaks that rule. A request can start while the legacy store owns the entries, and the legacy store saves the entry. Its `after_create` raises the event. If the request is then retried after ownership flips to Timekeeping, `forward_carried_create` resends the stored body under a carried idempotency key. Timekeeping has no receipt for that key, so it performs the write as new and sends no replay header. To Timekeeping the answer is fresh. To the event history it is a duplicate.

## Solution

A store's replay flag is only reliable for writes that store has seen before. Do not use it to decide whether some other store already announced the create.

In `Timekeeping::Gateway`:

- `forward_create` (fresh branch) and `local_create` (the `local_call` branch) call `created_entry(..., replayed: ...)`.
- `forward_carried_create` calls `hydrate(answer.row, ...)` only. It must never call `created_entry`, because the legacy `after_create` already raised the event for this create.
- `replay_local` hits return before any emit.

Before you send a new create exit through `created_entry`, ask which store raised the event for the first attempt. If that store is not the one whose replay flag you are reading, the flag cannot tell you anything about it.

## Why it matters

The failure is silent. Each carried retry returns the right entry, so the only symptom is a second `TimesheetEntries::Created` in the event history for one entry. Making all create exits share one emit path looks like a natural refactor, and it would bring this bug back. One example guards against it, and it fails only because its stub answers without the replay header.

## Evidence

PR #542 changes `app/services/timekeeping/gateway.rb`. `forward_create` and `local_create` now end in `created_entry(..., replayed: ...)`. `forward_carried_create` reads `answer.row` and calls only `hydrate`. The comment on `created_entry` says the event is raised for a create another store owns, and that a stored-receipt answer raises nothing.

The same pull request extends the example `resends the stored body byte for byte under the carried key when the retry matches an unexpired receipt` in `spec/services/timekeeping/gateway_spec.rb`. It now checks exactly one event from the pre-flip legacy create and none from the carried retry. A comment in the example explains that the stub answers as a fresh create with no replay header. The PR's review notes record a mutation check: the author briefly routed the carried path through `created_entry`, and that example failed until the code was restored.

`docs/architecture/timekeeping-soa.md` (changed in this pull request) says the gateway raises the event after a forwarded or prepared-store create that was not answered from a stored idempotency receipt.
