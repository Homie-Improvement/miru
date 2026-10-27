---
module: timekeeping
date: 2026-10-27
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: anchored
grounding_evidence: "spec/integration/timekeeping/local_relay_spec.rb in PR #194: route_local_relay_posts_into_app deletes rack.session before Rails.application.call, and the wrong-token example keeps TIMEKEEPING_SERVICE_TOKEN set while stubbing LocalSnapshotEndpoint.configured to wrap an HttpEndpoint with token wrong-token, then asserts status 401"
audience: both
related_components:
  - timekeeping_relay
  - internal_api
tags:
  - webmock
  - to-rack
  - service-token
  - in-process-http
  - authentication-tests
applies_when:
  - A spec sends a real HTTP request from app code back into the same Rails app through WebMock's to_rack
  - A spec must prove that a request with a wrong bearer token is refused
---

# Inject a wrong-token sender when routing HTTP back into the same app

## Context

Some end-to-end specs let a client class make its real HTTP POST, and use WebMock's `to_rack` to hand that request to `Rails.application` in the same process. This proves the receiving controller really checks the bearer token. Two traps come with it.

First, the sender and the receiver read the same process environment. In this repository `Timekeeping::LocalSnapshotEndpoint.configured` reads `TIMEKEEPING_SERVICE_TOKEN` to sign the request. `Internal::V1::BaseController` reads the same variable to check it. If a spec sets that variable to a "wrong" value, both sides change together. The tokens still match, the request is accepted, and a refusal test passes without ever exercising a refusal.

Second, WebMock's Rack adapter puts a plain Hash in `rack.session`. The app's cookie session store cannot read a plain Hash, so the request fails before it reaches the controller.

## Solution

Keep the receiver's token in the environment, unchanged. Build a separate sender that holds the wrong token, and inject it where the job gets its endpoint:

```ruby
with_timekeeping_service_token do
  route_local_relay_posts_into_app
  wrong = Timekeeping::LocalSnapshotEndpoint.new(
    endpoint: TimekeepingRelay::HttpEndpoint.new(url: local_relay_projection_url, token: "wrong-token"),
    logger: Logger.new(StringIO.new)
  )
  allow(Timekeeping::LocalSnapshotEndpoint).to receive(:configured).and_return(wrong)
  Timekeeping::RelayJob.perform_now
end
```

Then assert the refusal itself, not just its side effects: the status is `401`, the target rows do not exist, and the outbox rows are still unsent.

For this to work, keep the sender's constructor public (`initialize(endpoint:, logger:)`) and build the configured instance in one factory method (`configured`) that a spec can stub. Do not add a test-only bypass of the token check in app code.

When bridging into the app, strip the session keys WebMock adds. The internal API keeps no session, so nothing is lost:

```ruby
app = lambda do |env|
  env.delete("rack.session")
  env.delete("rack.session.options")
  Rails.application.call(env)
end
stub_request(:post, "#{url}/internal/v1/timekeeping/entry-snapshots").to_rack(app)
```

## Why it matters

A refusal test that changes both credentials is a false pass. It reports that bad tokens are refused while it only tests matching tokens. A later change that weakens the controller's check would keep it green. Separating the two sides in test code keeps the real authentication path under test, and needs no change to the app.

The same rule holds for any shared setting the sender and receiver both read in one process, such as a signing key or an expected host. Change only the sender's copy.

## Evidence

- PR #194, `spec/integration/timekeeping/local_relay_spec.rb`: `route_local_relay_posts_into_app` deletes `rack.session` and `rack.session.options` before calling `Rails.application`, with a comment that the cookie session store cannot read WebMock's plain Hash.
- PR #194, same file: the example "leaves the outbox unsent and timesheet_entries untouched when the sender's token does not match the receiver's" keeps the env token from `with_timekeeping_service_token`, stubs `Timekeeping::LocalSnapshotEndpoint.configured` to return an endpoint built with `"wrong-token"`, and asserts `statuses` equals `[401]`, no `TimesheetEntry` row, and every outbox row unsent.
- PR #194, `app/services/timekeeping/local_snapshot_endpoint.rb`: `configured` reads `Internal::V1::BaseController::SERVICE_TOKEN_ENV`, the same constant the controller uses, and `initialize(endpoint:, logger:)` is public so a spec can build the wrong-token sender.
