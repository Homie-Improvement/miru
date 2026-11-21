---
module: spec/support/timekeeping
date: 2026-11-21
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - timekeeping
tags:
  - net-http
  - retries
  - idempotency
  - replay-proofs
applies_when:
  - A spec helper sends HTTP requests with Net::HTTP and a test counts how many times a write reached the server
  - A replay or idempotency proof sends GET, PUT or DELETE requests
---

# Set Net::HTTP max_retries to 0 in single-send spec helpers

## Context

Net::HTTP resends an idempotent request (GET, PUT, DELETE) one more time when the connection drops before a reply arrives. It does this on its own. Nothing at the call site shows it.

That breaks any test whose point is "this write was sent once". A replay proof checks whether a second request is answered from a stored receipt or runs again. If the transport quietly sends a PUT twice, the test sees one call in its own code but the server sees two attempts.

## Solution

In any helper that promises one send, turn the transport retry off before the request:

```ruby
Net::HTTP.start(uri.host, uri.port, open_timeout: OPEN_TIMEOUT_SECONDS,
                                    read_timeout: READ_TIMEOUT_SECONDS) do |http|
  # Net::HTTP resends an idempotent request (GET, PUT, DELETE) once when
  # the connection drops; a replay proof must see exactly one attempt.
  http.max_retries = 0
  http.request(http_request)
end
```

Pin it with a test that uses a real local socket, not a stubbed reply. A stub never drops a connection, so it cannot show the retry. The test starts a `TCPServer` that closes the first connection without replying and answers any second one. It then expects the sender to raise and the server to have seen exactly one attempt.

## Why it matters

With the default setting, the dropped first connection is hidden: the second attempt gets a 200 and the helper reports success. A test built on that helper can certify "sent once, answered once" when the server actually handled two writes. That is the exact defect idempotency tests exist to catch.

POST is not retried by default, so a helper tested only with POST will look safe. The risk appears as soon as a caller sends PUT or DELETE.

## Evidence

- PR #544 adds `LiveHandoff.send_request` in `spec/support/timekeeping/live_handoff.rb`, which sets `http.max_retries = 0` with the comment quoted above.
- PR #544 adds the example "send_request sends a request once and raises when the connection drops, without a transport retry" in `spec/meta/timekeeping_live_handoff_spec.rb`. It sends a PUT to a `TCPServer` that drops the first connection, and expects `EOFError` and `attempts.size` equal to 1.
- The review of PR #544 ran the sender against such a server. With the default `max_retries` the result was reply 200 with 2 attempts. With `max_retries = 0` the result was `EOFError` with 1 attempt.
