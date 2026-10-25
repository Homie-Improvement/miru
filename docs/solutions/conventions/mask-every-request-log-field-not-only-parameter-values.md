---
module: timekeeping
date: 2026-10-25
problem_type: convention
component: observability
severity: high
evidence_grounding: anchored
grounding_evidence: timekeeping/lib/timekeeping/request_logger.rb and controller_log_subscriber.rb replace the stock Rails loggers to mask path, method and parameter names; config/application.rb sets log_rescued_responses = false; entries_logging_spec.rb and boot_spec.rb plant tokens in each field and assert they never appear
audience: both
related_components:
  - authentication
  - api_layer
tags:
  - logging
  - filter-parameters
  - secrets
  - rails-rack-logger
  - service-token
applies_when:
  - A Rails API promises that no log line ever carries a token
  - Adding a request log tag or a clear-text allow-list for parameters
---

# Mask every request log field, not only parameter values

## Context

The Timekeeping service promises that no log line carries a token. The first design relied on `config.filter_parameters` with an allow-list of id and date names. That filter masks parameter **values** only. A caller controls far more of what Rails writes to the log, and each of these fields let a planted credential through:

- The `Started GET "..."` line, written by `Rails::Rack::Logger`, filters only the query string. Path segments such as `/v1/companies/<token>/entries` stay in clear.
- The same line prints the raw HTTP method, which a caller can set to any text.
- Parameter **names** survive in both the start line's query string and the controller's `Parameters:` line (`?<token>=value`, `project_id[<token>]=5`).
- A JSON web token (a signed token with dots in it) in a path matches no route, and the routing-error line repeats the raw path.
- The `X-Request-Id` header goes into a log tag, and Rails' character cleaning keeps a hex token unchanged.
- An allowed name such as `project_id` with a token as its value passes a name-only allow-list. Even a shape rule (1-19 digits, `YYYY-MM-DD`, UUID) is not enough: the configured service token can itself have that shape.

## Solution

One pure module, `Timekeeping::LogSafety`, decides what may appear in clear, and every log writer asks it:

- `Timekeeping::RequestLogger` subclasses `Rails::Rack::Logger` and is swapped in for it. Its start line uses `loggable_method`, `loggable_path` and `loggable_query`. The path keeps only route words, ids and dates. The method shows only a known HTTP method name. The query masks any part whose name, including bracketed parts, is not on the allow-list.
- `Timekeeping::ControllerLogSubscriber` replaces the `ActionController` log subscriber, so that the `Parameters:` line also masks disallowed names at any depth.
- `config.action_dispatch.log_rescued_responses = false` drops the routing-error line. The 404 response itself needs no log line.
- `request_id_tag` keeps a UUID and logs any other value as `sha256:` plus 16 hex characters. A stable digest still lets readers match lines from one request.
- `filter_parameters` has two layers: a regexp that masks every name outside the allow-list, then a lambda that masks an allowed name's value unless it has that name's shape.
- Every rule that would show a value in clear also calls `held_credential?`, which compares the value with `TIMEKEEPING_SERVICE_TOKEN`. A 19-digit, date-shaped or UUID service token is therefore never shown in clear.

Test each field, not only query values. Plant a token in the path, the method, a parameter name, a parameter value, `X-Request-Id`, and a service token shaped as a number or a UUID. The routing-error line comes from a logger fixed at boot, so a request spec cannot capture it. `boot_spec.rb` checks it in a production child process.

## Why it matters

A token in a log can be replayed by anyone who reads that log, until the token expires or someone rotates it. The service token does not expire. A log spec that plants tokens only in query values passes while every other path leaks, so the test gives false confidence. The same rules apply to every later write route that inherits this logging.

## Evidence

- PR #38, head commit a7ad4ffcfd080034c4dece77b8be9ab84c4c541a.
- `timekeeping/lib/timekeeping/log_safety.rb`: `loggable_path`, `loggable_query`, `loggable_method`, `loggable_params`, `request_id_tag`, `held_credential?` and `PARAMETER_FILTERS`.
- `timekeeping/lib/timekeeping/request_logger.rb`: overrides `started_request_message`. Its comment says Rails masks only query values on that line.
- `timekeeping/lib/timekeeping/controller_log_subscriber.rb`: its comment says the parameter filter masks only values, so a token sent as a name would otherwise be logged.
- `timekeeping/config/application.rb`: the middleware swap, `log_rescued_responses = false`, and the subscriber detach and attach.
- `timekeeping/spec/requests/v1/entries_logging_spec.rb`: examples for tokens in the path, the HTTP method, parameter names, `X-Request-Id`, a UUID service token and a 19-digit service token.
- `timekeeping/spec/boot_spec.rb`: the production child-process example for a token in an unroutable path.
- `timekeeping/spec/lib/timekeeping/log_safety_spec.rb`: the examples for a service token shaped like an id or a date.

## Related

- The test capture technique itself is in `conventions/capture-api-controller-logger-when-proving-no-secret-is-logged.md`. This document covers which fields to plant tokens in.
