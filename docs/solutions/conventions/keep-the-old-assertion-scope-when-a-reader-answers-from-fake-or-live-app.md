---
module: spec/support/timekeeping
date: 2026-11-20
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - timekeeping
  - imports
tags:
  - timekeeping-regression
  - fake-vs-live
  - spec-helpers
  - assertion-strength
applies_when:
  - Porting spec assertions that read FakeTimekeeping (requests, outbox) to a helper that also reads the live Timekeeping app
  - Writing a shared reader whose result an example compares with eq or an exact count
---

# Keep the old assertion's scope when a reader answers from the fake or the live app

## Context

The forwarded examples in the Harvest importer spec used to read `FakeTimekeeping` directly. They read `fake.requests` for what the monolith sent, and the distinct entry ids in `fake.outbox` for what Timekeeping stored. In the live regression run the fake stays empty, so shared readers in `TimekeepingForwardingHelpers` now answer from the fake in an ordinary run and from the live app when `TimekeepingRegressionAdapter.current` is set.

The first version of those readers checked less than the old code did, and every example stayed green:

- The request reader kept only requests under the company entries path. The billed example's `eq(["POST"])` used to fail on any extra request, for example a GET to `/reservations`. With the filter, it no longer did.
- The stored-entry count left out discarded entries, both in the fake branch and in live SQL (`discarded_at IS NULL`). A regression that writes a duplicate entry and then discards it used to fail the `eq(2)` and `eq(1)` duplicate checks. With the filter, it passed them.

The example diffs looked safe because the expected values did not change. The narrowing was in the helper, where a reviewer of the examples does not look.

## Solution

Define each reader from the exact data the old assertion read, in both branches, and filter only when the old assertion filtered:

- `forwarded_timekeeping_requests(fake)` returns every request: all of `fake.requests`, or every request sent to the live app's host and port, whatever its path or method. `forwarded_create_requests` is a POST-only view of that one list, so it does not filter twice.
- `forwarded_stored_entry_count(fake, company:)` counts every entry ever stored. In the fake branch that is `fake.outbox.map { |row| row.fetch("entry").fetch("id") }.uniq.size`. In the live branch it is `SELECT count(*) FROM entries WHERE company_id = $1`, with no `discarded_at` filter.
- Write down the scope in the helper's comment, because exact checks depend on it. The helper says: "No path is filtered out, so an exact check on this list also fails when an extra request of any kind is sent."
- Pin the scope in the helper's contract spec with the case the narrow version would drop. Record a GET to another path and expect it in the list. Build an outbox with a discarded snapshot and expect it to be counted.

To review such a port, try one deliberate break for each reader: add an extra request on another path, or a duplicate that is later discarded. The ported example must still fail.

## Why it matters

These examples exist to catch duplicate writes and extra writes from the importer. A reader that counts fewer requests or fewer entries turns those checks into checks that always pass, in both the ordinary run and the live run. Because the expected values do not change, the green results look like proof that nothing changed.

## Evidence

- PR #472, `spec/support/timekeeping/forwarded_timekeeping_helpers.rb`: `forwarded_timekeeping_requests` maps all of `fake.requests`, and `ForwardedTimekeepingRequestLog.record` matches only host and `inferred_port`, with no path test. `forwarded_stored_entry_count` runs `SELECT count(*) FROM entries WHERE company_id = $1` and counts distinct outbox ids. The comments state that discarded entries are counted.
- PR #472, `spec/contracts/timekeeping/forwarded_timekeeping_helpers_spec.rb`: the example "reads every request the fake received, on any path, with only the POST as a create" expects a GET to `/reservations`. The example "counts each entry in the fake's outbox once, including an entry whose latest snapshot is discarded" expects `3`. The live example expects the `other-path` request to be recorded.
- Review of PR #472 found both narrowings: the entries-path filter and the discarded filter. The author removed both. For the path filter, the author's probe showed that the fake branch returned POST, PATCH and GET, and that the live log recorded the reservations GET. For the discarded filter, the contract spec returned 3.
- PR #472, `spec/services/imports/harvest_time_entries_importer_spec.rb`: the billed example keeps `expect(sent.pluck(:method)).to eq(["POST"])` over the full request list.
