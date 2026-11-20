---
module: spec/support/timekeeping
date: 2026-11-20
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - timekeeping
tags:
  - webmock
  - timekeeping-regression
  - idempotency-key
  - request-log
applies_when:
  - A spec must prove an Idempotency-Key was resent, or that requests went in a given order, while the live Timekeeping app runs
  - Adding a WebMock callback in spec/support
---

# Record requests sent to the live Timekeeping app with a WebMock after_request log, and clear it for each example

## Context

The importer specs check facts about the requests the monolith sent: the same `Idempotency-Key` sent twice, the order of creates, and the exact list of methods. `FakeTimekeeping` keeps its own `requests` list. The live Timekeeping app in the regression run does not keep one. Two other sources look usable, but neither can answer these questions:

- Idempotency receipts in the live database hold one row per key. They cannot show that a key was sent twice, or in what order.
- WebMock's request registry merges identical requests into one record with a count, and it does not keep order.

## Solution

Record the requests on the monolith side, as they leave. `ForwardedTimekeepingRequestLog` in `spec/support/timekeeping/forwarded_timekeeping_helpers.rb` does this:

- `WebMock.after_request { |request_signature, _response| ForwardedTimekeepingRequestLog.record(request_signature) }` adds one record for each request, in send order, so identical requests appear twice.
- `record` does nothing unless `TimekeepingRegressionAdapter.current` is set. It keeps a request only when its host and `inferred_port` match the live app's `base_url`.
- Each record is `{ method:, idempotency_key:, body: }`. The header is read case-insensitively, and an empty body becomes `{}`. This is the same shape the fake branch returns, so examples write each expected value once.
- `config.before { ForwardedTimekeepingRequestLog.clear }` empties the log. `WebMock.reset!` between examples leaves the callback registered, so without this hook one example's requests appear in the next example.
- `requests` returns a copy, and `record` builds a new array, so a caller cannot change the log.

## Why it matters

Without a log on the monolith side, a port to the live app must drop the checks that a key was resent or that requests went in order, or weaken them to receipt counts. Those are the checks that prove a rerun does not write a row twice. A log that is not cleared makes exact checks such as `eq(["POST"])` fail, or makes counts pass by accident, depending on which example ran first.

## Evidence

- PR #472, `spec/support/timekeeping/forwarded_timekeeping_helpers.rb`: adds `ForwardedTimekeepingRequestLog`, the `WebMock.after_request` registration, and `config.before { ForwardedTimekeepingRequestLog.clear }`. Its comment explains why receipts and the live app cannot serve as the log, and that `WebMock.reset!` leaves callbacks in place.
- PR #472, `spec/contracts/timekeeping/forwarded_timekeeping_helpers_spec.rb`: the first live-reader example sends a POST and a PATCH, and expects both in order. The next example starts with `expect(forwarded_timekeeping_requests(reader_fake)).to eq([])`. That example then records two identical POSTs as `k1 k1`, and it leaves out a request to port 4998. Because it records requests, the callback is still active after the reset between examples.
- PR #472, `spec/services/imports/harvest_time_entries_importer_spec.rb`: the rerun and drift examples read keys through `forwarded_create_requests(...).pluck(:idempotency_key)`. In the author's live run of the four forwarded groups, all 8 examples passed, with 0 failures.
