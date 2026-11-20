---
module: timekeeping_handoff
date: 2026-11-20
problem_type: convention
component: timekeeping_handoff
severity: medium
audience: both
related_components:
  - initializers
  - invoice_operations
tags:
  - initializer
  - to-prepare
  - database-connection
  - threads
  - keyword-defaults
applies_when:
  - An initializer or to_prepare block builds a long-lived object that later queries the database
  - A class takes a connection as a keyword argument with a default
---

# Resolve database connections at query time in objects an initializer builds

## Context

`config/initializers/timekeeping_handoff.rb` builds the handoff's owner integrations once, in a `to_prepare` block. It uses `to_prepare` because the handoff classes under `lib/` can be reloaded, and Rails runs that block at boot and again after each code reload. `OperationsSettle` and `OperationsSettle::MonolithPort` used to declare `connection: InvoiceOperationsRecord.connection` as a keyword default.

Ruby evaluates a keyword default when the object is built. For an object built at boot, that leases a connection on the boot thread. Request and job threads then reuse it. A boot with no reachable database would also try to connect.

## Solution

Default the keyword to `nil`, and resolve the connection in a private reader that each query calls:

```ruby
def initialize(connection: nil)
  @connection = connection
end

private

  def connection
    @connection || InvoiceOperationsRecord.connection
  end
```

An explicit `connection:` still wins, so specs and callers that pass one are unaffected. Apply the same check to any class that a boot-time block builds: nothing in its constructor should touch the database.

## Why it matters

An eager default reads like plain configuration, and it works in a single-threaded spec. The fault only shows up under a threaded server, or on a boot without a database. Moving a class into an initializer changes when its defaults run. Review its constructor at that point, not after a production incident.

## Evidence

- PR #428 changes both defaults to `nil` and adds the private `connection` readers in `lib/timekeeping/handoff/operations_settle.rb`. The new comment says a port built at boot should lease no connection on the boot thread.
- `config/initializers/timekeeping_handoff.rb` builds `OperationsSettle` and its `MonolithPort` inside `Rails.application.config.to_prepare`.
- `spec/lib/timekeeping/handoff/operations_settle_spec.rb` expects `InvoiceOperationsRecord` not to receive `:connection` while the settle integration is built. It also checks that queries with no explicit connection still go through `InvoiceOperationsRecord.connection`.
