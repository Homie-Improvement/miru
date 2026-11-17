---
module: spec/requests/api/v1/timesheet_entries
date: 2026-11-17
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - spec/support/timekeeping
tags:
  - idempotency-key
  - replay
  - request-specs
  - vacuous-assertion
  - header-lookup
applies_when:
  - A spec proves a retried write reused one key by checking that recorded values agree, e.g. `uniq.size` equals 1
  - A header or field is read through a helper that returns nil when the value is missing
---

# Assert forwarded values are present before asserting they agree

## Context

The client-key replay specs prove that a retried timesheet write reuses one Idempotency-Key. They collect the key from each request the fake Timekeeping server recorded, then check `expect(forwarded_keys.uniq.size).to eq(1)`.

That check has a blind spot. If the gateway stops sending the header, every recorded key is nil. Two nils are equal, so `uniq.size` is still 1 and the spec passes. The same holds for any "all values agree" check.

The blind spot widens when the read stops raising. Some old examples read the header with `request[:headers].fetch("Idempotency-Key")`, which raises when the header is missing. The shared helper `forwarded_idempotency_key(request)` matches the header name in any case, because the HTTP client may change its case. It ends in `&.last`, so a missing header returns nil instead of raising.

## Solution

Assert that every collected value is present before you assert anything about how the values compare. Put that check inside the helper that collects them, so no example can skip it:

```ruby
def client_key_forwarded_keys(method)
  requests = fake.requests.select { |request| request[:method] == method }
  keys = requests.map { |request| forwarded_idempotency_key(request) }
  expect(keys).to all(be_present)
  keys
end
```

Where a spec collects keys inline, add the presence check next to the agreement check:

```ruby
expect(forwarded_keys.size).to eq(2)
expect(forwarded_keys).to all(be_present)
expect(forwarded_keys.uniq.size).to eq(1)
```

Keep the count check too. Without it, zero recorded requests give an empty list that passes both `all(be_present)` and `uniq.size <= 1` checks.

## Why it matters

The replay rule says a retried write carries the client's key so Timekeeping replays the stored answer. A regression that drops the header sends each retry under no key at all, which is exactly the failure these specs exist to catch. A nil-tolerant agreement check reports that regression as a pass.

When you replace a raising read with a forgiving one, for case-insensitivity or to share one helper, check every caller for agreement checks that relied on the raise.

## Evidence

PR #346 makes this change:

- `spec/support/timekeeping/forwarded_timekeeping_helpers.rb` adds `forwarded_idempotency_key(request)`. It uses `find { |key, _value| key.to_s.casecmp?("Idempotency-Key") }&.last`, which returns nil for a missing header.
- `spec/requests/api/v1/timesheet_entries/gateway_spec.rb` adds `client_key_forwarded_keys(method)`. It runs `expect(keys).to all(be_present)` before returning the keys, with a comment that two nils would otherwise pass the same-key checks.
- `spec/requests/api/v1/timesheet_entries/bulk_actions/gateway_spec.rb` replaces a `fetch("Idempotency-Key")` read with `forwarded_idempotency_key(request)` in the bulk move example. The same change adds `expect(forwarded_keys).to all(be_present)` between the size check and `expect(forwarded_keys.uniq.size).to eq(1)`.
