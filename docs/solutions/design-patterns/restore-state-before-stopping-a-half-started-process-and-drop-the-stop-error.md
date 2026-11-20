---
module: spec/support/timekeeping
date: 2026-11-20
problem_type: design_pattern
component: testing_framework
severity: medium
audience: both
related_components:
  - TimekeepingLiveInstance
  - webmock
tags:
  - error-handling
  - secret-hygiene
  - cleanup-order
  - exception-cause
applies_when:
  - A start routine changes global state (ENV, WebMock settings) and then launches a process that can fail
  - Errors from the launched process can carry a database URL, token or key
---

# Restore state before stopping a half-started process, and drop the stop error

## Context

`TimekeepingRegressionAdapter.launch` changes global state, then starts a live Timekeeping instance. It narrows the WebMock allow list, starts the instance, and writes two client ENV keys. Any step can fail after the instance has begun. Errors from `TimekeepingLiveInstance` hold the output of its child processes, and that output can print the database URL. Errors in this suite end up in CI logs.

The first rescue called `instance.stop` before putting ENV and WebMock back. When `stop` also raised, that `IOError` escaped. The restore steps never ran. Ruby also set the original start error, which holds the secrets, as the cause of the `IOError`.

## Solution

In the rescue, do the cleanup in this order:

1. Restore the saved ENV keys and every WebMock setting that `disable_net_connect!` writes. These steps cannot fail on bad process state.
2. Stop the instance in a helper that rescues and discards its own error.
3. Raise a fixed-message error with `cause: nil`.

```ruby
rescue StandardError
  saved_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  saved_webmock.each { |name, value| WebMock::Config.instance.public_send(:"#{name}=", value) }
  stop_after_failed_start(instance)
  raise BootError, "the live Timekeeping instance did not start; ...", cause: nil
```

`cause: nil` is required. A `raise` inside a `rescue` sets the rescued error as its cause by default. Any reader that walks `error.cause` would then see the URL.

Snapshot every WebMock setting that `disable_net_connect!` writes (`allow_net_connect`, `allow_localhost`, `allow`, `net_http_connect_on_start`), not only the allow list. Otherwise a failed start can still change the network policy for later examples.

## Why it matters

Stopping first seems the natural order, because the process is the expensive thing. But the stop is the step most likely to fail when the start failed. If the stop runs first, one failure leaves the suite with a changed ENV, an open or narrowed WebMock policy, and a secret in the log. If the restore steps run first and the stop error is dropped, the caller always gets the same clean error.

## Evidence

- PR #458, `spec/support/timekeeping/regression_adapter.rb`: the rescue in `launch` restores `saved_env` and `saved_webmock` before `stop_after_failed_start`. That helper rescues `StandardError` and returns nil. The `BootError` is raised with `cause: nil`. `WEBMOCK_SETTINGS` lists the four settings that are saved.
- PR #458, `spec/integration/timekeeping/regression_adapter_spec.rb`: the example "a failed start whose instance also fails to stop still raises the clean BootError and restores WebMock and env" makes `stop` raise an `IOError` that contains the URL. It asserts a `BootError` with a nil cause, no URL or token in the message, and the earlier WebMock and ENV values.
- In the review of PR #458, that example was run with the old rescue order put back. It failed with `expected #<IOError> to be a kind of TimekeepingRegressionAdapter::BootError`, and it passed with the new order.
