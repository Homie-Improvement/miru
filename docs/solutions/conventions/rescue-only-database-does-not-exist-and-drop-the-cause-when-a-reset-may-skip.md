---
module: Timekeeping test harness
date: 2026-11-18
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - PostgreSQL
  - pg gem
tags:
  - database-reset
  - error-handling
  - secret-leak
  - exception-cause
applies_when:
  - A spec-support helper connects to a database named by an environment URL and is allowed to do nothing when that database does not exist yet.
---
# Rescue only "database does not exist" and drop the cause when a reset may skip

## Context

`TimekeepingDatabaseReset.reset!` empties the Timekeeping database and puts back its admission row. The issue allows one silent no-op: when the database does not exist yet, there is nothing to empty.

The first version rescued every `PG::ConnectionBad` and returned `nil`. That is the same answer as a successful reset. A down server, a wrong password or an unreachable host all looked like "reset done". Callers then ran against rows that were never emptied and a stale admission generation, and nothing showed the reset was skipped.

## Solution

Rescue the connection error, but return `nil` only when the server's message says this exact database is missing. Raise everything else.

```ruby
def connect(url, name)
  PG.connect(url)
rescue PG::ConnectionBad => e
  return nil if e.message.include?("database #{PG::Connection.quote_ident(name)} does not exist")

  raise PG::ConnectionBad, "could not connect to the Timekeeping database #{name.inspect}", cause: nil
end
```

Two details matter in the re-raise:

- The new message names only the database, never the URL. The URL can carry a password and a host into CI logs.
- `cause: nil` is required. Ruby sets `cause` to the rescued exception by default when you raise inside a `rescue`. The original libpq message names the host, so without `cause: nil` a clean message still leaks it through the cause chain that error reporters print.

Test the failure branch offline: point a `_test` database name at an unreachable port, and assert the error is raised, names the database, and has no password, no host and no cause.

## Why it matters

A blanket rescue copied from an existing spec reads as following a repo pattern. In a helper whose job is to guarantee a clean state, it hides the one failure the caller most needs to see. And a carefully scrubbed message is not enough on its own: the automatic `cause` brings the unscrubbed text back.

## Evidence

- PR #373, `spec/support/timekeeping/timekeeping_database_reset.rb`: `connect` returns `nil` only when the message includes `database "<name>" does not exist`, and otherwise raises `PG::ConnectionBad` with a message naming only the database and `cause: nil`. Its comment states that the original error can carry the URL's host.
- PR #373, `spec/meta/timekeeping_owner_state_spec.rb`: the example "reset! raises, naming only the database, when a _test database cannot be reached" uses `port=1` and `dbname=timekeeping_unreachable_test`, and asserts the message excludes the password and `127.0.0.1` and that `error.cause` is nil. The live example "reset! does nothing when the named _test database does not exist yet" asserts the no-op still returns `nil`.
- The review of PR #373 found the earlier blanket rescue returned `nil` for every connection failure; the author narrowed it in this change.
