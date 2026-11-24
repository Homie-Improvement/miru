---
module: timekeeping
date: 2026-11-24
problem_type: design_pattern
component: service_layer
severity: high
audience: both
related_components:
  - integration
tags:
  - reservation-client
  - prepare
  - tenant-isolation
  - fail-closed
  - abort
applies_when:
  - A local save relies on a remote service's answer to decide which tenant owns each referenced record
  - The same remote call is replayed internally by commit or abort to learn an operation's state
---

# Check a prepare answer's entry companies on the save, but not on its replays

## Context

Under the Timekeeping owner, the monolith's projection lags, so only Timekeeping's prepare answer can say which company holds an entry. PR #603 makes `Timekeeping::ReservationClient#prepare` the check that refuses another company's entry. Issue #520 quotes the design's rule L8: Timekeeping's prepare response is authoritative, and the monolith keeps a second check that uses each entry's company from that response. If the check is too loose, entries can cross tenants. If it runs on the wrong calls, operations can get stuck.

## Solution

- **The answer must carry companies.** The prepare 200 row in `ANSWER_TABLE` matches only when `entries_in(body)` is not nil. That requires an array of items with an integer entry id and an integer-or-null company, read through the contract's `response_entry_fields`. A missing or malformed list matches no row, so it is `retryable`, never `prepared`.
- **Exact match, item by item.** `company_mismatches` refuses with `not_found` three kinds of entry:
  - every requested entry not confirmed under `request.company_id`;
  - every entry listed under any other company, even when another item lists it under the right one;
  - every listed entry the request did not name.
- A null company is refused the same way, which matches the monolith's own rule for an entry with no company.
- **Replays skip the check.** `abort`, `replayed_state` (used by commit) and abort's two replays call `prepare_answer`, which has no company check. An operation that failed the check must still be abortable. If the replays ran the check, abort would keep seeing `refused` and stay retryable for ever.

## Why it matters

Two lenient checks look correct but are not. A check that asks "does any item name the right company?" accepts `(11, 7)` beside `(11, 8)`. A check that never compares against the request's id list accepts extra entries. Treating a body with no companies as success makes the check pass whenever the remote omits the field. Putting the check inside the shared `prepare` method also catches the replays, which turns a clean refusal into an abort that never ends.

## Evidence

- PR #603, `app/services/timekeeping/reservation_client.rb`: `ENTRY_ID_FIELD, ENTRY_COMPANY_FIELD`, `entries_in`, `company_mismatches`, `prepare` versus the private `prepare_answer`, and `abort` / `replayed_state` switched to `prepare_answer`.
- PR #603, `app/services/invoices/reservation_outcome.rb` adds the frozen `entries` field, which is empty by default.
- PR #603, `spec/services/timekeeping/reservation_client_spec.rb`:
  - an answer listing entry 7 under companies 41 and 42 is refused for 7;
  - an extra unrequested entry 8 is refused for 8;
  - a missing or malformed list is `retryable`;
  - an abort completes although every replay lists the entry under company 99.
- In the review history, the reviewer ran a rails runner probe with request company 7, entries `[11]`, and an answer listing `(11, 7)` and `(11, 8)`. After the fix it returned `state: "refused"` with `[{entry_id: 11, reason: "not_found"}]`.
