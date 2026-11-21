---
module: timekeeping
date: 2026-11-21
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - reservations
  - invoices
tags:
  - fault-injection
  - dropping-http
  - prepare-abort
  - reservation-client
applies_when:
  - A spec wraps Timekeeping::ReservationHttp in TimekeepingContract::DroppingHttp to fake a lost prepare answer
---

# Drop only the first prepare answer when you fake a lost prepare

## Context

A lost prepare answer is a timeout or a 5xx after Timekeeping has already applied the prepare. To fake it, a spec wraps `Timekeeping::ReservationHttp` in `TimekeepingContract::DroppingHttp`. A `drop:` rule picks which answers to discard.

The save then fails and the product sends an abort. That abort replays prepare through the same client. A rule that drops every request ending in `/reservations/prepare` also drops those replays. The abort then never gets an answer.

## Solution

Make the drop rule stateful, so that it drops one answer only:

```ruby
dropped = false
drop = lambda do |_method, path|
  next false if dropped || !path.end_with?("/reservations/prepare")

  dropped = true
end
Timekeeping::ReservationClient.new(
  http: TimekeepingContract::DroppingHttp.new(Timekeeping::ReservationHttp.new, drop:)
)
```

Stub `Invoices::ReservationAdapters.for` to return this client only around the failing save. Restore it with `and_call_original` afterwards.

## Why it matters

When every prepare is dropped, the test checks a client that can never abort. It never checks the recovery path that the case is about. The example then fails or waits out its deadline for a reason that has nothing to do with the product.

## Evidence

- PR #541 adds `section_9_3_client_dropping_first_prepare` in `spec/integration/timekeeping/section_9_3_spec.rb`. Its comment says the later prepares, including the replays that the abort sends, get their answers.
- The "Prepare answer lost (timeout or 5xx)" example in the same file expects `Invoices::OperationErrors::PrepareRetryable`. It then waits until Timekeeping stores the operation as `aborted` and checks that the reservations equal the baseline taken before the save.
